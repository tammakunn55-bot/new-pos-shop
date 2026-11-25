-- SMART-POS v13.4.3 hotfix
-- Bind payment and goods-receipt RPCs to the PIN employee session.
-- Honor p_pay_now atomically so local AP/cash state matches the server.
begin;

drop function if exists public.receive_customer_payment(uuid,numeric,uuid,text,text,text);
create function public.receive_customer_payment(
  p_customer_id uuid, p_amount numeric, p_shift_id uuid,
  p_op_ref text default null, p_payment_method text default 'CASH',
  p_reference text default null, p_session uuid default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_actor uuid; v_id uuid; v_debt numeric; v_new_debt numeric; v_method text; v_status text;
  v_existing record;
begin
  v_actor := public.pos_check_perm(p_session, 'CUSTOMER_PAY', 'STAFF');
  if p_amount is null or p_amount <= 0 then raise exception 'ยอดรับชำระต้องมากกว่า 0'; end if;

  if p_op_ref is not null then
    perform pg_advisory_xact_lock(hashtextextended('customer-payment:' || p_op_ref, 0));
    select id, customer_id, amount, payment_method into v_existing
      from public.customer_payments where op_ref = p_op_ref;
    if found then
      v_method := upper(trim(coalesce(p_payment_method, 'CASH')));
      if v_method = 'เงินสด' then v_method := 'CASH'; end if;
      if v_existing.customer_id is distinct from p_customer_id
         or round(v_existing.amount, 2) is distinct from round(p_amount, 2)
         or v_existing.payment_method is distinct from v_method then
        raise exception 'รหัสรับชำระ % ถูกใช้กับข้อมูลอื่นแล้ว', p_op_ref using errcode = '23505';
      end if;
      return jsonb_build_object('payment_id', v_existing.id, 'duplicate', true);
    end if;
  end if;

  v_method := upper(trim(coalesce(p_payment_method, 'CASH')));
  if v_method = 'เงินสด' then v_method := 'CASH'; end if;
  if v_method not in ('CASH','TRANSFER') then raise exception 'วิธีรับชำระไม่ถูกต้อง'; end if;

  select debt into v_debt from public.customers where id = p_customer_id for update;
  if not found then raise exception 'ไม่พบลูกค้า'; end if;
  if round(p_amount, 2) > round(v_debt, 2) then
    raise exception 'ยอดรับชำระ % เกินยอดหนี้ค้าง %', p_amount, v_debt;
  end if;
  if v_method = 'CASH' and p_shift_id is not null then
    select status into v_status from public.shifts where id = p_shift_id;
    if not found then raise exception 'ไม่พบกะ'; end if;
    if v_status <> 'OPEN' then raise exception 'กะปิดแล้ว ไม่สามารถบันทึกรับเงินสดเข้ากะนี้ได้'; end if;
  end if;

  insert into public.customer_payments(customer_id, amount, shift_id, payment_method, reference, op_ref, received_by)
  values (p_customer_id, round(p_amount, 2), p_shift_id, v_method, p_reference, p_op_ref, v_actor)
  returning id into v_id;
  update public.customers set debt = debt - round(p_amount, 2)
    where id = p_customer_id returning debt into v_new_debt;
  insert into public.customer_ledger(customer_id, entry_type, amount, balance_after, ref_type, ref_id, created_by)
  values (p_customer_id, 'PAYMENT', -round(p_amount, 2), v_new_debt, 'PAYMENT', v_id::text, v_actor);
  if v_method = 'CASH' then
    insert into public.cash_ledger(shift_id, type, income, description, ref_id, payment_method, created_by)
    values (p_shift_id, 'CUSTOMER_PAYMENT', round(p_amount, 2), 'รับชำระหนี้ลูกค้า', v_id::text, 'CASH', v_actor);
  end if;
  perform public.pos_audit('CUSTOMER_PAYMENT', 'customer_payments', v_id::text,
    jsonb_build_object('customer_id', p_customer_id, 'amount', p_amount, 'method', v_method));
  return jsonb_build_object('payment_id', v_id, 'customer_id', p_customer_id,
    'amount', p_amount, 'balance', v_new_debt);
end $$;

drop function if exists public.receive_goods(text,uuid,text,integer,timestamptz,jsonb,uuid,boolean);
create function public.receive_goods(
  p_client_ref text, p_supplier_id uuid, p_doc_ref text, p_terms integer,
  p_received_at timestamptz, p_items jsonb, p_ap_id uuid default null,
  p_pay_now boolean default false, p_session uuid default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_actor uuid; x jsonb; v_po uuid; v_ap uuid; v_variant uuid; v_product uuid;
  v_qty numeric; v_cost numeric; v_total numeric := 0; v_shift uuid; v_existing record;
begin
  v_actor := public.pos_check_perm(p_session, 'GOODS_RECEIPT', 'MANAGER');
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'ไม่มีรายการรับสินค้า';
  end if;
  if p_supplier_id is not null and not exists (select 1 from public.suppliers where id = p_supplier_id) then
    raise exception 'ไม่พบผู้ขาย';
  end if;

  if p_client_ref is not null then
    perform pg_advisory_xact_lock(hashtextextended('goods-receipt:' || p_client_ref, 0));
    select id, supplier_id, doc_ref, terms, total into v_existing
      from public.purchase_orders where client_ref = p_client_ref;
    if found then
      if v_existing.supplier_id is distinct from p_supplier_id
         or v_existing.doc_ref is distinct from p_doc_ref
         or v_existing.terms is distinct from coalesce(p_terms, 30)
         or exists (
           with incoming as (
             select nullif(item->>'product_id', '')::uuid as product_id,
                    nullif(item->>'variant_id', '')::uuid as variant_id,
                    coalesce((item->>'quantity')::numeric, 0) as quantity,
                    coalesce((item->>'unit_cost')::numeric, 0) as unit_cost
               from jsonb_array_elements(p_items) as e(item)
           ),
           existing_items as (
             select product_id, variant_id, quantity, unit_cost
               from public.purchase_order_items where purchase_order_id = v_existing.id
           )
           select 1 from (
             (select * from incoming except all select * from existing_items)
             union all
             (select * from existing_items except all select * from incoming)
           ) as different_items
         ) then
        raise exception 'รหัสรับสินค้า % ถูกใช้กับเอกสารหรือรายการสินค้าอื่นแล้ว', p_client_ref
          using errcode = '23505';
      end if;
      select id into v_ap from public.accounts_payable where purchase_order_id = v_existing.id;
      return jsonb_build_object('po_id', v_existing.id, 'ap_id', v_ap,
        'total', v_existing.total, 'duplicate', true);
    end if;
  end if;

  insert into public.purchase_orders(client_ref, supplier_id, doc_ref, terms, received_at, created_by)
  values (p_client_ref, p_supplier_id, p_doc_ref, coalesce(p_terms, 30),
    coalesce(p_received_at, now()), v_actor) returning id into v_po;

  for x in select value from jsonb_array_elements(p_items) loop
    v_product := nullif(x->>'product_id', '')::uuid;
    v_variant := nullif(x->>'variant_id', '')::uuid;
    v_qty := coalesce((x->>'quantity')::numeric, 0);
    v_cost := coalesce((x->>'unit_cost')::numeric, 0);
    if v_qty <= 0 or v_cost < 0 then raise exception 'จำนวนหรือทุนรับสินค้าไม่ถูกต้อง'; end if;
    if v_variant is null then raise exception 'รายการรับสินค้าต้องระบุ variant_id'; end if;

    update public.product_variants set
      cost_price = case when v_cost <= 0 then cost_price
        when stock_quantity > 0 then round((stock_quantity * cost_price + v_qty * v_cost) / (stock_quantity + v_qty), 2)
        else v_cost end,
      stock_quantity = stock_quantity + v_qty
    where id = v_variant;
    if not found then raise exception 'ไม่พบรุ่นสินค้า %', v_variant; end if;

    insert into public.inventory_movements(variant_id, change_qty, reason, ref_type, ref_id, created_by)
    values (v_variant, v_qty, 'รับสินค้าเข้าสต็อก', 'PURCHASE', v_po, v_actor);
    insert into public.purchase_order_items(purchase_order_id, product_id, variant_id, quantity, unit_cost, line_total)
    values (v_po, v_product, v_variant, v_qty, v_cost, round(v_qty * v_cost, 2));
    v_total := v_total + round(v_qty * v_cost, 2);
  end loop;

  update public.purchase_orders set total = v_total where id = v_po;
  insert into public.accounts_payable(id, supplier_id, purchase_order_id, doc_ref, amount, credit_terms, status, paid_at)
  values (coalesce(p_ap_id, gen_random_uuid()), p_supplier_id, v_po, p_doc_ref, v_total,
    coalesce(p_terms, 30), 'OPEN', null)
  on conflict (id) do update set purchase_order_id = excluded.purchase_order_id,
    supplier_id = excluded.supplier_id, doc_ref = excluded.doc_ref,
    amount = excluded.amount, credit_terms = excluded.credit_terms
  returning id into v_ap;

  if coalesce(p_pay_now, false) then
    perform public.pos_check_perm(p_session, 'PURCHASE', 'STAFF');
    v_shift := public.pos_ensure_open_shift();
    insert into public.supplier_payments(ap_id, supplier_id, amount, paid_at, paid_by, note, payment_method, shift_id)
    values (v_ap, p_supplier_id, v_total, now(), v_actor,
      'ชำระพร้อมรับสินค้า ' || coalesce(p_doc_ref, ''), 'CASH', v_shift);
    insert into public.cash_ledger(shift_id, type, income, expense, description, ref_id, payment_method, created_by)
    values (v_shift, 'SUPPLIER_PAYMENT', 0, v_total,
      'จ่ายเจ้าหนี้ ' || coalesce(p_doc_ref, ''), v_ap::text, 'CASH', v_actor);
    update public.accounts_payable set status = 'PAID', paid_at = now() where id = v_ap;
    perform public.pos_audit('PAY_SUPPLIER', 'accounts_payable', v_ap::text,
      jsonb_build_object('amount', v_total, 'method', 'CASH', 'posted_cash', true));
  end if;

  perform public.pos_audit('RECEIVE_GOODS', 'purchase_orders', v_po::text,
    jsonb_build_object('total', v_total, 'items', jsonb_array_length(p_items), 'paid_now', coalesce(p_pay_now, false)));
  return jsonb_build_object('po_id', v_po, 'ap_id', v_ap, 'total', v_total,
    'paid_now', coalesce(p_pay_now, false), 'shift_id', v_shift);
end $$;

grant execute on function public.receive_customer_payment(uuid,numeric,uuid,text,text,text,uuid) to authenticated;
grant execute on function public.receive_goods(text,uuid,text,integer,timestamptz,jsonb,uuid,boolean,uuid) to authenticated;

notify pgrst, 'reload schema';
commit;
