# คู่มือ deploy v13.5.0 (ปิดช่องโหว่ PIN/session/XSS)

> ลำดับสำคัญ: **สำรอง → ทดลองบน staging → รัน SQL → deploy เว็บ → ตรวจผล → (ค่อย) เปิด strict_session**

## 0. เตรียมตัว
1. ในแอปเครื่องหลัก: ตั้งค่า > สำรองข้อมูลเป็นไฟล์ (เก็บนอกเครื่อง)
2. Supabase: Database > Backups (หรือ `pg_dump`) ก่อนแก้ฐานข้อมูล
3. ถ้ามี Supabase project ทดสอบ ให้ทำขั้นตอน 1-3 บนนั้นก่อน

## 1. รัน SQL (ครั้งเดียว)
Supabase > SQL Editor > วางไฟล์ `sql/migrations/0013_server_side_pin_and_strict_session.sql` > Run
- ไฟล์มี self-test คำนวณ PBKDF2 เทียบค่ามาตรฐาน ถ้าผิดจะ **rollback ทั้งชุดเองพร้อมข้อความ error** (ยังไม่มีอะไรเปลี่ยน)
- ฐานข้อมูลใหม่ใช้ `SMART-POS-FULL-v13_4.sql` ไฟล์เดียวได้ (รวม 0013 แล้ว)
- เวอร์ชันเว็บเก่าที่ยังเปิดอยู่จะไม่พัง: ขอ session ไม่ได้และกลับไปใช้กติกาเดิมจนกว่าจะอัปเดตเว็บ

## 2. Deploy เว็บ
```bash
npm install
npm run build      # รัน check + contract-check + vite build
```
อัปโหลดเนื้อใน `dist/` แล้วให้ทุกเครื่องรีเฟรช 1–2 ครั้งเพื่อให้ service worker รับเวอร์ชันใหม่ (`package.json` = 13.5.0)

## 3. ตรวจว่าทำงานจริง
1. ล็อกอินพนักงาน (CASHIER) **ขณะออนไลน์** 1 ครั้งต่อคน
2. SQL Editor:
   ```sql
   select u.name, (s.pin_crypt is not null) as upgraded
   from app_user_secrets s join app_users u on u.id = s.app_user_id order by 1;
   ```
   คนที่ล็อกอินแล้วต้องเป็น `true` (ครั้งแรกอาจช้า 1–3 วินาทีเพราะต้องตรวจ PIN เดิมซ้ำฝั่งเซิร์ฟเวอร์)
3. ทดสอบว่าช่องโหว่ปิดแล้ว: เปิด DevTools บนเครื่องแคชเชียร์ นำ `pinHash` ของผู้จัดการจาก `localStorage.pos_full_db_state` ไปเรียก
   `getSupabaseClient().rpc('employee_login',{p_app_user_id:'<id ผู้จัดการ>',p_pin_hash:'<hash>'})` ต้องได้ `ok:false` และ **ไม่นับเป็นการเดาผิด**
4. ทดสอบ XSS: สร้างหมวดหมู่ชื่อ `a');alert(1);//` แล้วเปิดหน้าแก้ไขสินค้า/เลือกหมวดหมู่ ต้องไม่มี alert และเลือกหมวดได้ปกติ

## 4. เปิด strict_session (ทำเมื่อพร้อมเท่านั้น)
เงื่อนไขก่อนเปิด:
- ทุกคนที่ใช้งานเคยล็อกอินออนไลน์แล้ว (ข้อ 3.2 เป็น `true`)
- เครื่องหน้าร้านล็อกอิน Supabase ด้วยบัญชี **CASHIER** (ผูกด้วย `owner_link_auth_user`) ไม่ใช่บัญชี OWNER/MANAGER ร่วมกัน — ไม่เช่นนั้นการกันเลี่ยงสิทธิ์จะไม่ได้ผล
- บัญชี MANAGER ที่ผูก Supabase ต้องตั้ง PIN ในแอปแล้ว (เพื่อให้ได้ session)
```sql
insert into public.pos_flags(key, enabled) values ('strict_session', true)
on conflict (key) do update set enabled = true, updated_at = now();
```
ย้อนกลับทันที: `update public.pos_flags set enabled = false where key = 'strict_session';`
ข้อควรรู้: คิวซิงก์ที่สร้างตอนออฟไลน์นานเกิน 12 ชม. (session หมดอายุ) จะเข้าสถานะ `needs_review` ตามกลไก v13.4.4

## 5. ย้อนกลับ
- เว็บ: deploy `dist/` เวอร์ชันก่อนหน้า
- strict: ปิดด้วยคำสั่งข้างต้น
- PIN ฝั่งเซิร์ฟเวอร์: คอลัมน์ `pin_crypt` ไม่เป็นอันตรายถ้าค้างไว้ หากต้องกลับไป logic เดิมจริง ๆ ให้รันฟังก์ชัน `pos_check_pin`/`trg_secret_pin` เดิมจากไฟล์ v13.4.4 (เว็บ v13.4.4 ต้องใช้คู่กัน)

## 6. ยังไม่ได้ทำ / แนะนำต่อ
- **CSP + SRI**: ยังไม่ใส่ เพราะแอปใช้ inline handler และต้องทดสอบกับเครื่องพิมพ์/แจ้งเตือน/รูปภาพภายนอกก่อน ควรตั้ง header ที่โฮสต์ และ self-host `supabase-js`
- PIN 6 หลักที่เก็บ hash ไว้ในเครื่องเพื่อล็อกอินออฟไลน์ ยังถูกเดาแบบออฟไลน์ได้ถ้าเครื่อง/ไฟล์ backup หลุด (ทำให้ช้าด้วย PBKDF2 แต่ไม่ปลอดภัยเด็ดขาด) → เก็บไฟล์ backup อย่างปลอดภัย ล็อกเครื่อง
- `get_my_pin_hash` ยังคืน hash ของบัญชีตัวเอง (ใช้ตั้งค่าเครื่องใหม่) แต่ใช้ล็อกอินแทนไม่ได้แล้ว
- เก็บเงินเป็นสตางค์ (จำนวนเต็ม), unit test ตรรกะเงิน/สต็อก, แยก `03-core-app.js` เป็นโมดูล, แจ้งเตือนเมื่อ localStorage เต็ม
- **SQL ชุดนี้ยังไม่ได้รันบน PostgreSQL จริง** (ไม่มีในสภาพแวดล้อมที่ตรวจ) ตรวจเฉพาะอัลกอริทึม PBKDF2 เทียบ Python/Node ให้ตรงกัน จึงต้องทดสอบบน staging ก่อนเสมอ
