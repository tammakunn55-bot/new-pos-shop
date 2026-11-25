-- SMART-POS v13.5.0 security hotfix
-- 1) ตรวจ PIN ที่ฝั่งเซิร์ฟเวอร์: เซิร์ฟเวอร์รับ "PIN ดิบ" (4-12 หลัก) เท่านั้น ไม่รับ hash จากเบราว์เซอร์อีกต่อไป
--    hash ที่ค้างอยู่ใน localStorage / ไฟล์ backup จึงเอาไปล็อกอินแทนไม่ได้ (แก้ pass-the-hash)
-- 2) PIN เดิม (PBKDF2/SHA-256 จากเบราว์เซอร์) จะถูกตรวจฝั่งเซิร์ฟเวอร์ด้วยการคำนวณซ้ำจาก PIN ดิบ
--    แล้วอัปเกรดเป็น bcrypt (pin_crypt) อัตโนมัติเมื่อผู้ใช้ล็อกอินออนไลน์ครั้งแรก
-- 3) โหมด strict_session (ปิดไว้ก่อน): เมื่อเปิด RPC ที่ใช้ pos_check_perm ต้องมี session พนักงาน
--    (ยกเว้นเครื่องที่ล็อกอิน Supabase ด้วยบัญชี OWNER)
-- รันซ้ำได้ ปลอดภัย: ถ้าการคำนวณ PBKDF2 บนฐานข้อมูลนี้ผิดพลาด ชุดนี้จะ rollback ทั้งหมดเอง (ดู self-test)
begin;

create extension if not exists pgcrypto with schema extensions;

alter table public.app_user_secrets add column if not exists pin_crypt text;

create table if not exists public.pos_flags (
  key text primary key,
  enabled boolean not null default false,
  updated_at timestamptz not null default now()
);
alter table public.pos_flags enable row level security;
revoke all on public.pos_flags from anon, authenticated;

-- PBKDF2-HMAC-SHA256 (32 ไบต์) ให้ผลตรงกับ WebCrypto ฝั่งเบราว์เซอร์; ใช้ภายในเท่านั้น
create or replace function public.pos_pbkdf2_hex(p_pin text, p_salt_hex text, p_iter integer)
returns text language plpgsql immutable set search_path = public, extensions as $$
declare
  k bytea := convert_to(p_pin, 'UTF8');
  u bytea; t bit(256); i integer; res text := '';
begin
  if p_iter is null or p_iter < 1 or p_iter > 300000 then raise exception 'iteration ไม่อยู่ในช่วงที่รองรับ'; end if;
  u := hmac(decode(p_salt_hex, 'hex') || '\x00000001'::bytea, k, 'sha256');
  t := ('x' || encode(u, 'hex'))::bit(256);
  for i in 2..p_iter loop
    u := hmac(u, k, 'sha256');
    t := t # ('x' || encode(u, 'hex'))::bit(256);
  end loop;
  for i in 0..7 loop
    res := res || lpad(to_hex(substring(t from i * 32 + 1 for 32)::bit(32)::bigint), 8, '0');
  end loop;
  return res;
end $$;
revoke all on function public.pos_pbkdf2_hex(text, text, integer) from public, anon, authenticated;

-- self-test: ถ้าไม่ตรงกับค่ามาตรฐาน (คำนวณด้วย Python/Node) ให้ยกเลิกทั้งชุด
do $$ begin
  if public.pos_pbkdf2_hex('123456', '000102030405060708090a0b0c0d0e0f', 1000)
     is distinct from '6e3849111be8d3070634220666e93c55dbfd75e923f34d35716805464c0a7eaf' then
    raise exception 'self-test PBKDF2 ไม่ผ่าน: อย่าใช้ migration นี้กับฐานข้อมูลนี้';
  end if;
end $$;

-- รับเฉพาะ PIN ดิบ; ค่าที่ไม่ใช่ตัวเลข (เช่น hash จากแอปเวอร์ชันเก่า) ปฏิเสธทันทีโดยไม่นับเป็นการเดาผิด
-- (พารามิเตอร์ยังชื่อ p_pin_hash เพื่อไม่ให้ลายเซ็นฟังก์ชัน/สิทธิ์เดิมเปลี่ยน แต่ความหมายคือ PIN ดิบ)
create or replace function public.pos_check_pin(p_app_user_id uuid, p_pin_hash text) returns boolean
language plpgsql security definer set search_path = public, extensions as $$
declare s record; v_ok boolean := false; v_parts text[];
begin
  if p_pin_hash is null or p_pin_hash !~ '^[0-9]{4,12}$' then return false; end if;
  select * into s from public.app_user_secrets where app_user_id = p_app_user_id for update;
  if not found then return false; end if;
  if s.locked_until is not null and s.locked_until > now() then
    raise exception 'PIN ถูกล็อกชั่วคราว ลองใหม่อีกประมาณ % นาที',
      ceil(extract(epoch from (s.locked_until - now())) / 60);
  end if;

  if s.pin_crypt is not null then
    v_ok := (s.pin_crypt = crypt(p_pin_hash, s.pin_crypt));
  elsif s.pin_hash like 'pbkdf2$%' then
    v_parts := string_to_array(s.pin_hash, '$');
    if array_length(v_parts, 1) = 4 and v_parts[2] ~ '^[0-9]{1,6}$' and v_parts[3] ~ '^([0-9a-f]{2}){4,64}$' then
      v_ok := public.pos_pbkdf2_hex(p_pin_hash, v_parts[3], v_parts[2]::integer) = v_parts[4];
    end if;
  elsif s.pin_hash ~ '^[0-9a-f]{64}$' then
    v_ok := encode(digest(p_pin_hash, 'sha256'), 'hex') = s.pin_hash;
  end if;

  if v_ok then
    update public.app_user_secrets set failed_count = 0, locked_until = null, updated_at = now(),
      pin_crypt = case when pin_crypt is null then crypt(p_pin_hash, gen_salt('bf', 10)) else pin_crypt end
      where app_user_id = p_app_user_id;
    return true;
  end if;
  update public.app_user_secrets set
      failed_count = failed_count + 1,
      locked_until = case when failed_count + 1 >= 5 then now() + interval '15 minutes' end,
      updated_at = now()
    where app_user_id = p_app_user_id;
  return false;
end $$;

-- ซิงก์ผู้ใช้จากแอปยังส่ง hash มาใน app_users.pin (ใช้เป็นตัวตั้งต้นสำหรับ PIN ใหม่/ที่เปลี่ยน)
-- แต่ hash นี้ใช้ล็อกอินไม่ได้ และการซิงก์ซ้ำด้วยค่าเดิมจะไม่รีเซ็ตตัวนับล็อกหรือ bcrypt อีกต่อไป
create or replace function public.trg_secret_pin() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.pin is distinct from 'secret' then
    insert into public.app_user_secrets(app_user_id, pin_hash) values (new.id, new.pin)
    on conflict (app_user_id) do update set
      pin_crypt    = case when app_user_secrets.pin_hash is distinct from excluded.pin_hash then null else app_user_secrets.pin_crypt end,
      failed_count = case when app_user_secrets.pin_hash is distinct from excluded.pin_hash then 0 else app_user_secrets.failed_count end,
      locked_until = case when app_user_secrets.pin_hash is distinct from excluded.pin_hash then null else app_user_secrets.locked_until end,
      pin_hash     = excluded.pin_hash,
      updated_at   = now();
    update public.app_users set pin = 'secret' where id = new.id;
  end if;
  return null;
end $$;

-- โหมด strict_session
create or replace function public.pos_check_perm(p_session uuid, p_perm text, p_legacy text default 'STAFF')
returns uuid language plpgsql stable security definer set search_path = public, auth as $$
declare v_user uuid; u record;
begin
  if p_session is null then
    if exists (select 1 from public.pos_flags where key = 'strict_session' and enabled)
       and public.pos_current_role() is distinct from 'OWNER' then
      raise exception 'ต้องล็อกอินพนักงานด้วย PIN ก่อน (ไม่พบเซสชัน)' using errcode = '42501';
    end if;
    if p_legacy = 'MANAGER' then return public.pos_require_manager(); end if;
    return public.pos_require_staff();
  end if;
  select s.app_user_id into v_user from public.pos_sessions s
   where s.token_hash = encode(sha256(convert_to(p_session::text, 'UTF8')), 'hex')
     and not s.revoked and s.expires_at > now();
  if v_user is null then raise exception 'เซสชันหมดอายุ กรุณาล็อกอินใหม่' using errcode = '42501'; end if;
  select * into u from public.app_users where id = v_user and is_active;
  if not found then raise exception 'บัญชีนี้ถูกปิดการใช้งาน' using errcode = '42501'; end if;
  if u.role = 'OWNER' or u.permissions ? 'ALL' or u.permissions ? p_perm then return v_user; end if;
  raise exception 'ไม่มีสิทธิ์: %', p_perm using errcode = '42501';
end $$;

notify pgrst, 'reload schema';
commit;
