import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const sync = readFileSync(resolve(root, 'public/js/10-sync-queue-pin.js'), 'utf8');
const receive = readFileSync(resolve(root, 'public/js/05-enterprise-repair.js'), 'utf8');
const sql = readFileSync(resolve(root, 'sql/SMART-POS-FULL-v13_4.sql'), 'utf8');

assert.match(sync, /\['adjust',\s*'sale',\s*'delete',\s*'return',\s*'payment',\s*'receive'\]\.includes\(op\.type\)/,
  'payment/receive operations must capture the employee session');
assert.match(sync, /p_reference:\s*p\.reference\s*\|\|\s*p\.transferReference\s*\|\|\s*null,\s*p_session:\s*p\.sessionToken\s*\|\|\s*null/,
  'customer payment RPC must pass p_session');
assert.match(sync, /p_pay_now:\s*!!p\.payNow,\s*p_session:\s*p\.sessionToken\s*\|\|\s*null/,
  'goods receipt RPC must pass p_session');
assert.match(receive, /selectedPayMode==='CASH'&&!ok\('PURCHASE'\)/,
  'cash payment during goods receipt must require PURCHASE permission');
assert.match(sql, /receive_customer_payment[\s\S]*?p_session uuid default null[\s\S]*?pos_check_perm\(p_session,\s*'CUSTOMER_PAY',\s*'STAFF'\)/,
  'receive_customer_payment must enforce CUSTOMER_PAY through employee session');
assert.match(sql, /receive_goods[\s\S]*?p_session uuid default null[\s\S]*?pos_check_perm\(p_session,\s*'GOODS_RECEIPT',\s*'MANAGER'\)/,
  'receive_goods must enforce GOODS_RECEIPT through employee session');
assert.match(sql, /if coalesce\(p_pay_now,\s*false\) then[\s\S]*?supplier_payments[\s\S]*?cash_ledger[\s\S]*?status = 'PAID'/,
  'p_pay_now must create supplier payment, cash expense, and mark AP paid');
assert.match(sql, /hashtextextended\('customer-payment:'[\s\S]*?hashtextextended\('goods-receipt:'/,
  'payment and receipt idempotency checks must be serialized');

// ---- v13.5.0: PIN ฝั่งเซิร์ฟเวอร์ / strict session / XSS ----
import vm from 'node:vm';
import { readdirSync } from 'node:fs';
const session = readFileSync(resolve(root, 'public/js/19-session-token.js'), 'utf8');
const core = readFileSync(resolve(root, 'public/js/03-core-app.js'), 'utf8');
const login = readFileSync(resolve(root, 'public/js/05-enterprise-repair.js'), 'utf8');
const mig = readFileSync(resolve(root, 'sql/migrations/0013_server_side_pin_and_strict_session.sql'), 'utf8');

assert.doesNotMatch(session, /p_pin_hash:\s*u\.pinHash/, 'employee_login ต้องไม่ส่ง hash ที่เก็บในเครื่องเป็นรหัสผ่าน');
assert.match(session, /window\.__posLoginPin/, 'ต้องส่ง PIN ดิบผ่านตัวแปรชั่วคราว');
assert.match(login, /__posLoginPin = pin;[\s\S]*?finally \{ window\.__posLoginPin = null; \}/, 'ต้องล้าง PIN ดิบหลัง emit ทุกครั้ง');
assert.match(mig, /p_pin_hash !~ '\^\[0-9\]\{4,12\}\$'[\s\S]*?return false/, 'pos_check_pin ต้องปฏิเสธค่าที่ไม่ใช่ PIN ดิบ');
assert.match(mig, /pin_crypt = crypt\(p_pin_hash/, 'ต้องอัปเกรดเป็น bcrypt');
assert.match(mig, /strict_session/, 'ต้องมีโหมด strict_session');
assert.match(mig, /self-test PBKDF2/, 'ต้องมี self-test PBKDF2');
assert.ok(sql.includes('trg_secret_pin') && sql.includes('v13.5.0'), 'FULL SQL ต้องรวม patch 0013');

// escapeHTML / jsq: ทดสอบพฤติกรรมจริงจากซอร์ส
const grab = (name) => { const m = core.match(new RegExp('function ' + name + '\\([^)]*\\) \\{[\\s\\S]*?\\n      \\}')); assert.ok(m, 'ไม่พบ ' + name); return m[0]; };
const ctx = { window: {} }; vm.createContext(ctx);
vm.runInContext(grab('escapeHTML') + '\n' + grab('jsq'), ctx);
assert.equal(vm.runInContext('escapeHTML(0)', ctx), '0', 'escapeHTML(0) ต้องได้ "0"');
assert.equal(vm.runInContext('escapeHTML(null)', ctx), '');
assert.equal(vm.runInContext('escapeHTML(\'<img onerror=x>\')', ctx), '&lt;img onerror=x&gt;');
const evil = `');alert(1);//"><svg onload=x>`;
ctx.evil = evil;
const q = vm.runInContext('jsq(evil)', ctx);
assert.ok(!/['"<>&;()]/.test(q), 'jsq ต้องไม่เหลืออักขระอันตราย: ' + q);
assert.equal(vm.runInContext(`'${q}'`, ctx), evil, 'jsq ต้องถอดกลับเป็นค่าเดิมเมื่อ JS ประมวลผลสตริง');
assert.equal(vm.runInContext(`'${vm.runInContext('jsq("สว่าน-01")', ctx)}'`, ctx), 'สว่าน-01');
const allJs = Object.fromEntries(readdirSync(resolve(root, 'public/js')).filter((f) => f.endsWith('.js')).map((f) => [f, readFileSync(resolve(root, 'public/js', f), 'utf8')]));
const bare = Object.entries(allJs).flatMap(([k, s]) => s.split('\n').map((l, i) => [k, i + 1, l]))
  .filter(([, , l]) => /on(click|change|input)="[^"]*'\$\{(?!jsq\()/.test(l));
assert.equal(bare.length, 0, 'พบ inline handler ที่ยังไม่ครอบด้วย jsq: ' + bare.slice(0, 3).map((b) => b[0] + ':' + b[1]).join(', '));

console.log('ผ่าน: employee session, RPC permissions, immediate supplier payment, idempotency contracts');
console.log('ผ่าน: server-side PIN, strict_session, escapeHTML/jsq, inline handler');
