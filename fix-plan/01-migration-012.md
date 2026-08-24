# خطة إصلاح الترحيل 0012 — تعدد العملات والتصنيفات

**المخطط:** مخطط_إصلاح_الترحيل0012 (Migration-012 Remediation Architect)
**النطاق:** `debt-ledger-supabase/supabase/migrations/202608180012_multi_currency_and_categories.sql` وتفاعلاته مع الترحيلات 0001/0002/0006/0008/0010 وعقد RPC مع الموبايل.
**المصادر المقروءة فعلياً:** تقارير `analysis-reports/01-schema-constraints.md` و`05-double-entry.md` و`06-multi-currency.md`، والترحيلات `202607120001` (أسطر 150–209)، `202607120002` (كاملاً)، `202608140006` (أسطر 1–100)، `202608140008` (أسطر 120–180)، `202608140010` (كاملاً)، `202608180012` (كاملاً، 209 أسطر).
**الحكم المسبق (من التقارير الثلاثة مجتمعة):** الترحيل 0012 لا يُطبَّق أصلاً (سياسة RLS تستدعي `has_business_permission`/`business_permission` غير الموجودين — 0012:38–43)، ولو طُبِّق جزئياً لعطّل كل إدراج في `ledger_entries` (مقارنة `direction='in'` في 0012:59 مقابل enum `('debit','credit')` في 0001:20)، ولكسر عزل المستأجرين بدالة عامة بلا تفويض (0012:114–209).

---

## 1. القرار المعماري المحسوم

### الخيارات

| الخيار | الوصف | الإيجابيات | السلبيات |
|---|---|---|---|
| **أ — عملة واحدة لكل متجر (الوضع الراهن)** | إبقاء تريجر 0010 (سطرا 329–330) الذي يفرض `currency_code = businesses.currency_code`، وحذف ميزة تعدد العملات كلياً | أقل جهد؛ المحاسبة والكشوفات تبقى صحيحة بلا تعديل | إزالة محدد العملات من الموبايل (مبني وجاهز: `create_ledger_entry_sheet.dart:43-47`، `currencyBreakdown` في `merchant_controller.dart:126-137`)؛ لا يلبي واقع السوق اليمني (تعامل شائع بـ YER/SAR/USD) |
| **ب — تعدد عملات حر لكل قيد (ما حاوله 0012)** | أي قيد بأي عملة ISO | أقصى مرونة | فوضى بيانات؛ أخطاء إدخال تصبح قيوداً مالية؛ كشوفات وتقارير شبه مستحيلة الضبط |
| **ج — تعدد عملات لكل متجر بقائمة مسموحة وفصل صارم** | المتجر له عملة أساسية + قائمة `additional_currencies`؛ كل قيد بعملة واحدة من القائمة؛ الأرصدة والكشوفات والمحاسبة مجمّعة حسب العملة؛ **لا يوجد أي تحويل بين العملات** | يلبي حاجة السوق؛ يمنع أخطاء الإدخال؛ يحافظ على صحة المحاسبة بشرط وحدة القياس لكل قيد يومية؛ متوافق مع واجهة الموبايل الجاهزة | يتطلب تعديل طبقة المحاسبة (عملة في journal lines) والـ views والكشوفات |

### القرار: **الخيار ج — تعدد عملات لكل متجر، بفصل كامل بين العملات وبلا تحويل**

**المبررات:**
1. واجهة الموبايل مبنية فعلياً لتعدد العملات (محدد عملات، فلترة، أرصدة مجزأة — تقرير 06 نقاط إيجابية 6)؛ إزالتها هدر لعمل منجز وتأخير إضافي.
2. الواقع التجاري اليمني متعدد العملات فعلاً (YER/SAR/USD)؛ منتج ديون بلا تعدد عملات غير قابل للبيع في هذا السوق.
3. الفصل الصارم بلا تحويل يبقي المعادلة المحاسبية صحيحة شرط إضافة `currency_code` لأسطر اليومية وتجميع ميزان المراجعة حسب العملة (يحل ملاحظة 05-حرج-1 و06-عالي-7).
4. القائمة المسموحة لكل متجر تمنع فساد البيانات الصامت (مشكلة التحويل الصامت إلى 'YER' في 0012:147–150) وتلغي الحاجة لأسعار صرف في هذه المرحلة.
5. التفعيل تدريجي: `additional_currencies` الافتراضي فارغ → السلوك عند الإطلاق مطابق تماماً لعملة واحدة، ويُفعَّل لكل متجر على حدة في المرحلة 1 (feature flag على مستوى البيانات).

**مسلّمات مصاحبة ملزمة:**
- لا جمع لعملات مختلفة في رقم واحد في أي view أو كشف أو إجمالي — كل تجميع `group by currency_code`.
- `credit_limit` وفحص «السداد يتجاوز الرصيد» يُقيَّمان **لكل عملة على حدة** (مجموع قيود العميل بنفس عملة القيد فقط).
- كل قيد يومية (بما فيه اليدوي) أحادي العملة؛ العملة مخزنة على رأس القيد وأسطره.

---

## 2. استراتيجية التعامل مع الترحيل المكسور الحالي

### حقيقة حاسمة
الترحيل 0012 **لا يمكن أن يكون قد نجح في أي بيئة**: `create policy` في سطر 38–43 يفشل حتماً (`function public.has_business_permission(uuid, business_permission) does not exist`). ولأن الملف بلا `begin/commit` (بخلاف 0001/0006/0010)، فالتنفيذ المقسّم يترك **حالة جزئية**: الأعمدة الخمسة (0012:5–10) والجدول (0012:13–26) والتريجر المكسور (0012:108–111) والدالة المعطوبة (0012:114–209) قد توجد، بينما السياسة لا توجد. والأخطر: إن وُجد التريجر المكسور فكل INSERT في `ledger_entries` يفشل.

### شجرة القرار حسب سيناريو النشر

**خطوة التحقق الأولى (إلزامية قبل أي قرار):** في كل بيئة (محلية، staging، production) نفّذ:

```sql
-- هل سُجل الترحيل كمطبَّق؟
select version from supabase_migrations.schema_migrations where version = '202608180012';
-- هل توجد أجزاء منه رغم عدم تسجيله؟
select to_regclass('public.customer_currency_balances') as tbl,
       to_regprocedure('public.command_create_ledger_entry(uuid,public.ledger_entry_type,numeric,varchar,text,text,text,text,text,timestamptz,date,text,uuid,text)') as fn;
select tgname from pg_trigger where tgname = 'trg_ledger_entry_currency_balance';
```

**السيناريو أ — لم يُنشر (لا سجل في schema_migrations ولا أجزاء):** *الحالة المتوقعة في كل البيئات.*
- **القرار: حذف ملف `202608180012_multi_currency_and_categories.sql` نهائياً** واستبداله بترحيل جديد `202608190013_multi_currency_redo.sql` مكتوب من الصفر (القسم 3).
- المبرر: الترحيلات غير المسجلة في `schema_migrations` ليست تاريخاً ملزماً؛ إبقاء ملف فاشل في المجلد يكسر `supabase db reset` وكل بيئة جديدة. إعادة كتابة نفس الملف مرفوضة لأن اسمه/وصفه يكذبان المحتوى ولأن أي بيئة جزئية ستحتاج ترحيلاً تصحيحياً منفصلاً على أي حال.

**السيناريو ب — نُشر جزئياً (لا سجل في schema_migrations لكن توجد أجزاء):** *متوقع في أجهزة مطورين جربوا الترحيل يدوياً.*
- نفس قرار حذف الملف، **بالإضافة**: الترحيل الجديد 0013 يبدأ بكتلة تنظيف idempotent (قسم 3.0) تسقط التريجر والدالة والسياسات والجدول المشتق `if exists` قبل إعادة البناء الصحيح. الجدول مشتق بالكامل من `ledger_entries` (المرجع الأصلي) فيُعاد ملؤه بالـ backfill — لا فقدان بيانات فعلية.
- **تحقق إلزامي قبل التنظيف:** التريجر المكسور إن وُجد يعني أن قاعدة البيانات **مشلولة الكتابة حالياً**؛ يُسقط فوراً يدوياً (`drop trigger if exists trg_ledger_entry_currency_balance on public.ledger_entries;`) كإجراء طوارئ قبل أي شيء.

**السيناريو ج — نُشر كاملاً وسُجل في schema_migrations:** *مستحيل نظرياً (السياسة تفشل حتماً)، لكنه ممكن إذا حرّر أحدهم الملف يدوياً على السيرفر.*
- **لا يُحذف الملف ولا يُعدَّل** (تاريخ مسجل). يُضاف الترحيل التصحيحي 0013 بنفس كتلة التنظيف + إعادة البناء + الـ backfill. بما أن كل محتوى 0012 إما مكسور أو مشتق، فإسقاطه وإعادة بنائه آمن.
- يُوثَّق الانحراف اليدوي في سجل الحوكمة.

**الخلاصة:** قرار واحد يغطي الجميع — **حذف الملف (أو تجميده في السيناريو ج) + ترحيل بديل 0013 بكتلة تنظيف idempotent في مقدمته.** لا يُستخدم خيار «إعادة كتابة 0012 في مكانه» إطلاقاً.

---

## 3. تصميم الترحيل البديل `202608190013_multi_currency_redo.sql`

الملف كامل داخل `begin; ... commit;` (إصلاح ملاحظة 01-منخفض-5). الترتيب التالي إلزامي.

### 3.0 كتلة التنظيف (idempotent — تغطي السيناريوهين ب/ج)

```sql
drop trigger if exists trg_ledger_entry_currency_balance on public.ledger_entries;
drop function if exists private.trig_update_customer_currency_balance();
drop function if exists public.command_create_ledger_entry(uuid,public.ledger_entry_type,numeric,varchar,text,text,text,text,text,timestamptz,date,text,uuid,text);
drop policy if exists customer_currency_balances_select_member on public.customer_currency_balances;
drop policy if exists customer_currency_balances_service_modify on public.customer_currency_balances;
drop table if exists public.customer_currency_balances;  -- مشتق؛ يُعاد ملؤه من ledger_entries
-- الأعمدة تبقى (add column if not exists لاحقاً idempotent)؛ attachment_url يُبقى مؤقتاً — انظر 3.2
```

### 3.1 قائمة العملات المسموحة لكل متجر

```sql
alter table public.businesses
  add column if not exists additional_currencies text[] not null default '{}';
alter table public.businesses
  add constraint businesses_additional_currencies_iso
  check (not exists (select 1 from unnest(additional_currencies) c
                     where c !~ '^[A-Z]{3}$' or c = currency_code));
```

دالة مساعدة تُستخدم في التريجر والدوال:

```sql
create or replace function private.business_allows_currency(p_business_id uuid, p_currency text)
returns boolean language sql stable security definer set search_path='' as $$
  select exists (
    select 1 from public.businesses b
    where b.id = p_business_id and b.status = 'active'
      and (b.currency_code = p_currency or p_currency = any(b.additional_currencies))
  )
$$;
```

### 3.2 أعمدة التصنيف — enums منضبطة بدل النص الحر

تصلح ملاحظة 01-متوسط-3.2 و06-متوسط-13. القيم تطابق ما يرسله الموبايل فعلاً (`ledger_entry_model.dart:10-11` + `merchant_repository.dart:178-179` الذي يرسل `'discount'`):

```sql
do $$ begin
  create type public.ledger_entry_category as enum ('goods','service','cash','transfer','discount','other');
exception when duplicate_object then null; end $$;
do $$ begin
  create type public.ledger_payment_method as enum ('cash','bank_transfer','cheque','offset','discount','other');
exception when duplicate_object then null; end $$;

alter table public.ledger_entries
  add column if not exists reference_number text,
  add column if not exists bank_or_agent_name text,
  add column if not exists attachment_url text;  -- مؤقت/مهمل: مرحلة 1 تنقله إلى منظومة files (0001:257-276, 0006:79-93)

-- تحويل العمودين النصيين (إن وُجدا من نشر جزئي) إلى enum بأمان
alter table public.ledger_entries alter column category drop default;
alter table public.ledger_entries
  alter column category type public.ledger_entry_category
  using (case when category in ('goods','service','cash','transfer','discount','other') then category else 'other' end)::public.ledger_entry_category,
  alter column category set default 'goods'::public.ledger_entry_category;
-- نفس النمط لـ payment_method مع قائمته
alter table public.ledger_entries alter column category set not null;
alter table public.ledger_entries alter column payment_method set not null;
```

### 3.3 جدول `customer_currency_balances` المصحح

يصلح: FK الخاطئ (0012:17 → `profiles`)، وCASCADE (0012:15–16)، وسياسة service_role الميتة (0012:45–48)، وسياسة الدالة غير الموجودة (0012:38–43)، وغياب الحماية من التعديل المباشر (01-عالي-2.4):

```sql
create table if not exists public.customer_currency_balances (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  business_customer_id uuid not null references public.business_customers(id) on delete restrict,
  customer_id uuid references public.customers(id) on delete restrict,  -- المصحح: customers لا profiles
  currency_code varchar(3) not null check (currency_code ~ '^[A-Z]{3}$'),
  current_balance numeric(20,4) not null default 0.0000,
  total_debits numeric(20,4) not null default 0.0000,
  total_credits numeric(20,4) not null default 0.0000,
  entry_count bigint not null default 0,  -- bigint بدل integer (01-منخفض-6)
  last_entry_at timestamptz,
  updated_at timestamptz not null default now(),
  constraint uq_customer_currency unique(business_customer_id, currency_code)
);

alter table public.customer_currency_balances enable row level security;
revoke all on public.customer_currency_balances from anon, authenticated;
grant select on public.customer_currency_balances to authenticated;
-- الكتابة حصراً عبر تريجر security definer؛ لا سياسة service_role (يتجاوز RLS أصلاً)

create policy customer_currency_balances_select_member
on public.customer_currency_balances for select to authenticated
using (
  private.is_business_member(business_id, null)
  or (customer_id is not null and private.is_customer_owner(customer_id))  -- المصحح: مقارنة customers.id بدلالة المالك لا auth.uid() مباشرة (يصلح 05:سطر42)
);

create trigger trg_ccb_updated_at before update on public.customer_currency_balances
for each row execute function private.set_updated_at();
-- منع التعديل/الحذف المباشر من أي مسار غير التريجر: لا منح UPDATE/DELETE أصلاً + تريجر رادع دفاعي
create trigger trg_ccb_no_manual_mutation before update or delete on public.customer_currency_balances
for each row execute function private.prevent_update_delete();
```

> ملاحظة تصميمية: التريجر الرادع `prevent_update_delete` لا يتعارض مع تريجر الأرصدة لأن تحديث الرصيد يتم بـ `insert ... on conflict do update` من دالة `security definer` — يجب استثناء هذا المسار. الحل: التريجر الرادع يفحص `current_setting('private.balance_trigger', true) = 'on'` الذي تضبطه دالة التريجر عبر `set_config` قبل التحديث. إن تعذر، يُكتفى بعدم منح UPDATE/DELETE (الرادع أمن دفاعي إضافي — قرار التنفيذ للمهندس مع اختبار pgTAP يثبت أن تريجر الأرصدة يعمل والتعديل اليدوي ممنوع).

### 3.4 تريجر الأرصدة المصحح (debit/credit)

```sql
create or replace function private.trig_update_customer_currency_balance()
returns trigger language plpgsql security definer set search_path='' as $$
declare v_sign smallint; v_debit numeric(20,4) := 0; v_credit numeric(20,4) := 0;
begin
  if new.direction = 'debit' then            -- المصحح: كان 'in' (0012:59)
    v_sign := 1;  v_debit := new.amount;
  else                                        -- 'credit' — كان else يفترض 'out'
    v_sign := -1; v_credit := new.amount;
  end if;
  perform set_config('private.balance_trigger','on',true);
  insert into public.customer_currency_balances
    (business_id,business_customer_id,customer_id,currency_code,current_balance,total_debits,total_credits,entry_count,last_entry_at,updated_at)
  values
    (new.business_id,new.business_customer_id,new.customer_id,new.currency_code,
     new.amount*v_sign,v_debit,v_credit,1,coalesce(new.occurred_at,now()),now())
  on conflict (business_customer_id, currency_code) do update set
    customer_id     = coalesce(excluded.customer_id, customer_currency_balances.customer_id),
    current_balance = customer_currency_balances.current_balance + excluded.current_balance,
    total_debits    = customer_currency_balances.total_debits + excluded.total_debits,
    total_credits   = customer_currency_balances.total_credits + excluded.total_credits,
    entry_count     = customer_currency_balances.entry_count + 1,
    last_entry_at   = greatest(customer_currency_balances.last_entry_at, excluded.last_entry_at),
    updated_at      = now();
  return new;
end $$;

create trigger trg_ledger_entry_currency_balance
after insert on public.ledger_entries
for each row execute function private.trig_update_customer_currency_balance();
```

### 3.5 توحيد مسار إنشاء القيود — مسار API واحد

**يُحذف نهائياً** `public.command_create_ledger_entry` الخاص بـ 0012 (ثغرة 01-حرج-1.4 و06-عالي-10). بدلاً منه تُوسَّع الدالة الأصلية `private.command_create_ledger_entry` (0010:346–376) — التي تحوي كل الضوابط: قفل `for update`، `is_archived`، idempotency ناعم (0010:360–361)، `command_receipts` (0010:372–373)، فحص الرصيد وحد الائتمان — لتقبل المعاملات الجديدة، ويُعاد نشر الغلاف العام `public.create_ledger_entry` **بالتوقيع الكامل الذي يرسله الموبايل** (`merchant_repository.dart:129-143`) لحل كسر العقد الحرج (05-حرج-2، 06-حرج-4):

```sql
create or replace function private.command_create_ledger_entry(
  p_business_customer_id uuid, p_entry_type public.ledger_entry_type, p_amount numeric,
  p_description text,
  p_currency_code varchar default null,           -- جديد؛ null = عملة المتجر الأساسية
  p_category public.ledger_entry_category default 'goods',
  p_payment_method public.ledger_payment_method default 'cash',
  p_reference_number text default null,
  p_bank_or_agent_name text default null,
  p_attachment_path text default null,            -- يُقبل مؤقتاً لعقد الموبايل؛ يُخزن في attachment_url
  p_occurred_at timestamptz default now(), p_due_date date default null,
  p_external_reference text default null,
  p_client_request_id uuid default gen_random_uuid(),
  p_source_device_id uuid default null
) returns uuid language plpgsql security definer set search_path='' as $$
-- ... نفس جسم 0010:354-375 مع التعديلات:
--   v_currency := upper(trim(coalesce(p_currency_code, <عملة المتجر>)));
--   if v_currency !~ '^[A-Z]{3}$' or not private.business_allows_currency(v_bc.business_id, v_currency)
--     then raise exception 'Currency not allowed for this business' using errcode='22023'; end if;
--     (يصلح التحويل الصامت إلى YER — 0012:147-150 — بالرفض بدل الاستبدال)
--   فحص الرصيد وحد الائتمان بفلترة العملة:
--   select coalesce(sum(case when direction='debit' then amount else -amount end),0)
--     into v_balance from public.ledger_entries
--    where business_customer_id = p_business_customer_id and currency_code = v_currency;  -- يصلح 0010:365 و05-منخفض-10
--   الإدراج يشمل الأعمدة الجديدة + source_device_id يبقى uuid (يصلح 0012:128)
$$;

create or replace function public.create_ledger_entry(
  p_business_customer_id uuid, p_entry_type public.ledger_entry_type, p_amount numeric,
  p_currency_code varchar default null,
  p_category public.ledger_entry_category default 'goods',
  p_payment_method public.ledger_payment_method default 'cash',
  p_reference_number text default null, p_bank_or_agent_name text default null,
  p_attachment_path text default null,
  p_description text default null,                 -- يُرفض إن كان null أو أقصر من حرفين (قيد 0001:167) — يصلح 0012:123
  p_occurred_at timestamptz default null, p_due_date date default null,
  p_client_request_id uuid default null
) returns uuid language sql set search_path='' as $$
  select private.command_create_ledger_entry(...nفس التمرير...)
$$;
grant execute on function public.create_ledger_entry(uuid,public.ledger_entry_type,numeric,varchar,public.ledger_entry_category,public.ledger_payment_method,text,text,text,text,timestamptz,date,uuid) to authenticated;
```

> **تنبيه عقد:** ترتيب/أسماء المعاملات يجب أن تطابق حرفياً ما يرسله `merchant_repository.dart:129-143` (PostgREST يطابق بالأسماء). المعامل `p_source_device_id` يُسند داخلياً من سياق الجهاز عند الحاجة؛ إن أصرّ الموبايل على إرساله يُضاف للتوقيع العام. هذه النقطة مشتركة مع مخطط عقد API — اعتمادية صريحة (قسم 7).

وبالمثل تُوسَّع `private.command_apply_customer_discount` (0010:378–402) و`public.apply_customer_discount` بمعامل `p_currency_code varchar default null` بنفس قواعد التحقق وفلترة الرصيد بالعملة (يصلح 06-حرج-4 للخصم)، مع منحة EXECUTE محدثة.

### 3.6 تعديل تريجر التحقق `validate_ledger_entry_insert`

يستبدل سطرا 0010:329–330 (فرض عملة واحدة) بعضوية القائمة المسموحة:

```sql
create or replace function private.validate_ledger_entry_insert() returns trigger ... as $$
-- ... كما في 0010:321-344 مع استبدال فحص العملة بـ:
  if not private.business_allows_currency(new.business_id, new.currency_code) then
    raise exception 'Currency or business status mismatch';
  end if;
-- بقية الفحوص كما هي (تطابق tenant/customer، الأدوار، قواعد العكس)
$$;
```

`create or replace` يحدّث الدالة ويبقي تريجر 0002:328–330 مربوطاً. مع `additional_currencies` الفارغ افتراضياً، السلوك مطابق للحالي تماماً → لا كسر للاختبارات القائمة.

### 3.7 العملة في طبقة القيد المزدوج

يصلح 06-عالي-7 و01-متوسط-3.6:

```sql
alter table public.journal_entries
  add column if not exists currency_code varchar(3) check (currency_code ~ '^[A-Z]{3}$');
alter table public.journal_entry_lines
  add column if not exists currency_code varchar(3) check (currency_code ~ '^[A-Z]{3}$');
-- تعبئة تاريخية: من القيد التشغيلي المصدر، ومن عملة المتجر للقيود اليدوية
update public.journal_entries je set currency_code = le.currency_code
  from public.ledger_entries le where le.id = je.source_ledger_entry_id and je.currency_code is null;
update public.journal_entries je set currency_code = b.currency_code
  from public.businesses b where b.id = je.business_id and je.currency_code is null;
update public.journal_entry_lines jel set currency_code = je.currency_code
  from public.journal_entries je where je.id = jel.journal_entry_id and jel.currency_code is null;
alter table public.journal_entries alter column currency_code set not null;
alter table public.journal_entry_lines alter column currency_code set not null;
-- تريجر يفرض تطابق عملة السطر مع رأس القيد
```

وتُعدَّل `private.post_ledger_entry_journal` (0010:239–299) لتمرير `v_entry.currency_code` لرأس القيد وكل سطر (بما فيه مسار العكس 0010:269–272 الذي ينسخ أسطر القيد الأصلي — عملته مطابقة بحكم فحص العكس 0010:339)، وتُعدَّل `command_post_manual_journal` (0010:410–436) لتستقبل `p_currency_code` وتفرضه على كل الأسطر. ويُعاد بناء `account_trial_balance` (0010:465–477) بإضافة `jel.currency_code` إلى الـ select و`group by`. تريجر التوازن `assert_journal_entry_balanced` (0010:204–217) لا يحتاج تعديلاً لأن القيد أحادي العملة مفروض.

### 3.8 إصلاح الـ views والكشوفات (منع جمع العملات)

- `public.business_customer_balances` (0002:653–670): إضافة `le.currency_code` للـ select و`group by`؛ الصف بلا قيود يأخذ عملة المتجر. النتيجة صف لكل (عميل × عملة) — وهو ما يتوقعه الموبايل أصلاً (`currencyBreakdown`).
- `public.business_customer_account_positions` (0010:479–490): نفس التجميع حسب `le.currency_code` بدل عرض `b.currency_code` كعملة المجموع.
- `public.customer_account_overview` (0002:658–670): نفس النمط.
- `private.command_generate_statement` (0008:152–159): إضافة `and currency_code = v_currency` لاستعلامات opening/debits/credits والأسطر (0008:171–179)، مع معامل اختياري `p_currency_code` لفرع `business_customer` (الافتراضي: عملة المتجر) — يزيل التناقض الداخلي بين الفرعين (06-عالي-6).

### 3.9 المصالحة (Reconciliation)

```sql
create or replace function private.reconcile_customer_currency_balances(p_business_id uuid default null)
returns table(business_customer_id uuid, currency_code varchar, stored numeric, computed numeric, drift numeric)
language sql stable security definer set search_path='' as $$
  select le.business_customer_id, le.currency_code,
         coalesce(ccb.current_balance,0), sum(case when le.direction='debit' then le.amount else -le.amount end),
         coalesce(ccb.current_balance,0) - sum(case when le.direction='debit' then le.amount else -le.amount end)
  from public.ledger_entries le
  left join public.customer_currency_balances ccb
    on ccb.business_customer_id = le.business_customer_id and ccb.currency_code = le.currency_code
  where (p_business_id is null or le.business_id = p_business_id)
  group by le.business_customer_id, le.currency_code, ccb.current_balance
  having coalesce(ccb.current_balance,0) <> sum(case when le.direction='debit' then le.amount else -le.amount end)
$$;
```

تُستدعى من اختبار pgTAP (يجب أن ترجع صفر صفوف) وتُترك جاهزة لجدولة دورية في المرحلة 1 (يحل 01-عالي-2.4 و05-متوسط-6 جزئياً فيما يخص الجدول المشتق).

---

## 4. خطة ترحيل البيانات الموجودة

1. **قيود `ledger_entries` الحالية:** عملتها إلزامية منذ 0001 (سطر 166) وتريجر 0010 يفرض أنها = عملة المتجر → لا يوجد أي بيانات متعددة العملات تحتاج معالجة. `additional_currencies` الافتراضي `'{}'` يحافظ على هذا السلوك.
2. **Backfill أرصدة العملات** (داخل 0013 بعد إنشاء الجدول والتريجر):

```sql
insert into public.customer_currency_balances
  (business_id,business_customer_id,customer_id,currency_code,current_balance,total_debits,total_credits,entry_count,last_entry_at,updated_at)
select le.business_id, le.business_customer_id, le.customer_id, le.currency_code,
       sum(case when le.direction='debit' then le.amount else -le.amount end),
       sum(case when le.direction='debit' then le.amount else 0 end),
       sum(case when le.direction='credit' then le.amount else 0 end),
       count(*), max(le.occurred_at), now()
from public.ledger_entries le
group by le.business_id, le.business_customer_id, le.customer_id, le.currency_code
on conflict (business_customer_id, currency_code) do nothing;
```

   **معيار التحقق:** `select * from private.reconcile_customer_currency_balances()` ترجع صفر صفوف فور الترحيل.
3. **أعمدة التصنيف:** إن وُجدت من نشر جزئي، قيمها النصية تُحوَّل للـ enum بـ `case ... else 'other'` (3.2) — لا فقدان صفوف. إن لم توجد، `default` يملأ القديم تلقائياً (06-إيجابي-5).
4. **journal lines التاريخية:** تُعبأ عملتها من القيد المصدر/عملة المتجر (3.7) ثم تُقفل `not null` — قابلة للتحقق بعدّاد `where currency_code is null` = 0 قبل القفل.
5. **لا حذف لأي بيانات** في أي خطوة؛ الجدول الوحيد المسقط (`customer_currency_balances`) مشتق ويُعاد بناؤه كاملاً في الخطوة 2.

---

## 5. خطوات التنفيذ المرقمة

| # | المرحلة | الملف المستهدف | التغيير | معيار التحقق من النجاح | الاعتماديات | الجهد |
|---|---|---|---|---|---|---|
| 1 | [فوري — خلال 24 ساعة] | كل بيئات النشر | تنفيذ استعلامات التحقق الثلاثة (قسم 2) وتوثيق سيناريو كل بيئة | جدول موقّع: بيئة ↔ سيناريو أ/ب/ج | — | 0.25 يوم |
| 2 | [فوري — خلال 24 ساعة] | بيئات السيناريو ب فقط | إسقاط طارئ: `drop trigger if exists trg_ledger_entry_currency_balance on public.ledger_entries;` | INSERT تجريبي في `ledger_entries` ينجح | خطوة 1 | 0.25 يوم |
| 3 | [فوري — خلال 24 ساعة] | `supabase/migrations/202608180012_multi_currency_and_categories.sql` | حذف الملف من الفرع الرئيسي (السيناريو أ/ب) أو تجميده موثقاً (ج) | `supabase db reset` ينجح من الصفر؛ `git grep has_business_permission` بلا نتائج | خطوة 1 | 0.25 يوم |
| 4 | [فوري — خلال 24 ساعة] | وثيقة قرار معماري (ADR) | توقيع قرار «تعدد عملات لكل متجر بفصل صارم» (قسم 1) من مالك المنتج والهندسة | ADR معتمد؛ لا بدء تنفيذ قبله | — | 0.5 يوم |
| 5 | [مرحلة صفر — يحظر الإطلاق] | `supabase/migrations/202608190013_multi_currency_redo.sql` (جديد) | كتلة التنظيف 3.0 + `additional_currencies` + `business_allows_currency` (3.1) | الترحيل يُطبَّق على قاعدة نظيفة وعلى قاعدة جزئية بلا خطأ (idempotent) | 3، 4 | 0.5 يوم |
| 6 | [مرحلة صفر] | نفس الملف | enums التصنيف/السداد + تحويل الأعمدة (3.2) | `select distinct category, payment_method from ledger_entries` كلها ضمن الـ enums | 5 | 0.5 يوم |
| 7 | [مرحلة صفر] | نفس الملف | جدول `customer_currency_balances` المصحح + RLS + الحماية (3.3) | FK يشير `customers(id)`؛ INSERT يدوي من دور authenticated يفشل؛ SELECT للعضو والعميل المالك ينجح | 5 | 0.75 يوم |
| 8 | [مرحلة صفر] | نفس الملف | تريجر الأرصدة المصحح + backfill (3.4 + قسم 4-2) | قيد debit يرفع الرصيد وcredit يخفضه؛ `reconcile` ترجع 0 صفوف | 7 | 0.5 يوم |
| 9 | [مرحلة صفر] | نفس الملف | توسيع `private.command_create_ledger_entry` + إعادة نشر `public.create_ledger_entry` بالتوقيع الكامل + المنح (3.5) | استدعاء PostgREST بحمولة الموبايل الحرفية (12 معاملاً) ينجح؛ تكرار `client_request_id` يرجع نفس المعرف بلا خطأ؛ غير العضو يُرفض 42501 | 5، 6 | 1 يوم |
| 10 | [مرحلة صفر] | نفس الملف | توسيع `apply_customer_discount` بـ `p_currency_code` + فلترة الرصيد بالعملة (3.5) | خصم بعملة غير مسموحة يُرفض؛ خصم يتجاوز رصيد نفس العملة يُرفض | 9 | 0.5 يوم |
| 11 | [مرحلة صفر] | نفس الملف | تعديل `validate_ledger_entry_insert` (3.6) | قيد بعملة المتجر ينجح؛ بعملة غير مسموحة يُرفض؛ بعملة في `additional_currencies` ينجح | 5 | 0.25 يوم |
| 12 | [مرحلة صفر] | نفس الملف | عملة اليومية: أعمدة + تعبئة + تعديل `post_ledger_entry_journal` و`command_post_manual_journal` و`account_trial_balance` (3.7) | كل سطر يومية له عملة = عملة قيده؛ ميزان المراجعة مجمّع (حساب × عملة)؛ قيد يدوي بأكثر من عملة يُرفض | 5 | 1 يوم |
| 13 | [مرحلة صفر] | نفس الملف | إصلاح الـ views الثلاثة و`command_generate_statement` (3.8) | عميل تجريبي بقيدين بعملتين: كل view يرجع صفين منفصلين؛ كشف `business_customer` يفلتر بالعملة | 11 | 0.75 يوم |
| 14 | [مرحلة صفر] | نفس الملف | دالة المصالحة (3.9) | ترجع 0 صفوف بعد backfill؛ ترجع انحرافاً بعد UPDATE يدوي من service_role (اختبار سلبي) | 8 | 0.25 يوم |
| 15 | [مرحلة صفر] | `supabase/tests/database/004_multi_currency.sql` (جديد) | اختبارات pgTAP (قسم 6) | `supabase test db` أخضر بالكامل بما فيه 001–003 | 5–14 | 1 يوم |
| 16 | [مرحلة صفر] | `debt-ledger-supabase/full_schema.sql` | إعادة توليده من قاعدة مُرحَّلة نظيفة + اختبار CI يقارنه | يحتوي 0013 كاملاً؛ diff CI فارغ (يحل 01-متوسط-3.1) | 15 | 0.25 يوم |
| 17 | [مرحلة 1 — تجريبي مغلق] | بيانات `businesses` + الموبايل | تفعيل `additional_currencies` لمتاجر مختارة؛ سحب `customer_currency_balances` في `_pullRemoteUpdates` (اعتمادية على مخطط الموبايل — `sync_engine.dart:187-193`) | متجر تجريبي ثنائي العملة: أرصدة الموبايل = السيرفر بعد مزامنة كاملة | 9، 13، خطة الموبايل | 1 يوم (باكند فقط) |
| 18 | [مرحلة 1 — تجريبي مغلق] | ترحيل لاحق + الموبايل | نقل المرفقات من `attachment_url` إلى `files`/`ledger_entry_files` (0001:257-276) ثم إسقاط العمود | لا `attachment_url` في المخطط؛ المرفقات بـ sha256 عبر upload_sessions | تحديث الموبايل أولاً | 1 يوم |
| 19 | [مرحلة 2 — إطلاق تجاري] | Edge Functions + الموبايل | minor units لكل عملة في التنسيق (`generate-statement/index.ts:46-49`)، وإشعارات بعملة القيد (`process-automation-rules/index.ts:207,235`) | كشف PDF بعملة KWD يعرض 3 خانات؛ إشعار قيد SAR موسوم SAR | 13 | 0.5 يوم |
| 20 | [مرحلة 2 — إطلاق تجاري] | قرار منتج | تقارير مجمعة متعددة العملات بأسعار صرف (جدول `exchange_rates`) — **يُدرس ولا يُنفذ** قبل طلب صريح | ADR منفصل | — | يُقدَّر لاحقاً |

**الإجمالي:** 20 خطوة — فوري 4 · مرحلة صفر 12 · مرحلة 1 اثنتان · مرحلة 2 اثنتان. جهد الباكند الصرف ≈ 8.5 يوم عمل.

---

## 6. خطة التحقق والاختبار

### 6.1 اختبارات pgTAP الجديدة — `supabase/tests/database/004_multi_currency.sql` (plan تقريبي 18)

1. `has_table('customer_currency_balances')` و`has_column` للأعمدة الخمسة في `ledger_entries`.
2. FK الصحيح: `col_is_fk` / فحص `pg_constraint` أن `customer_id` يشير `customers(id)`.
3. تريجر الأرصدة: إدراج debit ثم credit بعملة المتجر → `current_balance` صحيح و`entry_count=2`.
4. رفض عملة غير مسموحة: `throws_ok` على إدراج قيد بـ 'SAR' و`additional_currencies='{}'`.
5. قبول عملة مسموحة: بعد `update businesses set additional_currencies='{SAR}'` → قيد SAR ينجح ويولّد صف رصيد ثانٍ.
6. رفض رمز غير صالح: `p_currency_code='$$$'` → استثناء 22023 (لا سقوط صامت).
7. idempotency: استدعاءان بنفس `client_request_id` → نفس `entry_id` وصف رصيد واحد.
8. التفويض: مستخدم غير عضو يستدعي `create_ledger_entry` → 42501.
9. فحص الرصيد لكل عملة: رصيد YER موجب لا يسمح بسداد SAR يتجاوز رصيد SAR (صفر).
10. حد الائتمان لكل عملة.
11. اليومية: قيد SAR يولّد `journal_entries.currency_code='SAR'` وأسطره كذلك؛ ميزان المراجعة يظهر صفاً لكل عملة.
12. قيد يدوي بأسطر مختلطة العملة → `throws_ok`.
13. الـ views: عميل بعملتين → صفان في `business_customer_balances` و`business_customer_account_positions`.
14. الكشف: `generate_statement` بفرع `business_customer` يجمع عملة واحدة فقط (إنشاء قيدين بعملتين والتحقق من `total_debits`).
15. المصالحة: `reconcile_customer_currency_balances()` ترجع 0 صفوف.
16. RLS: عضو متجر آخر لا يرى أرصدة المتجر الأول؛ العميل المالك المربوط يرى أرصدته فقط.
17. منع التعديل اليدوي: UPDATE مباشر على `customer_currency_balances` من authenticated يفشل.
18. `category='Goods'` (حرف كبير) يُرفض — انضباط الـ enum.

### 6.2 تحقق تكاملي

- `supabase db reset` من الصفر ثم `supabase test db` — أخضر بالكامل (يثبت أن حذف 0012 لم يكسر التسلسل وأن 0013 idempotent).
- تطبيق 0013 على نسخة من قاعدة جزئية مُصنَّعة يدوياً (محاكاة السيناريو ب) — ينجح ويزيل التريجر المكسور.
- تشغيل حمولة الموبايل الحرفية (JSON من `merchant_repository.dart:129-143`) عبر PostgREST على بيئة staging — نجاح إنشاء دين/سداد/خصم.
- اختبار تراجع: قاعدة staging عليها بيانات تجريبية → تطبيق 0013 → عدّ صفوف `ledger_entries` و`journal_entry_lines` قبل/بعد متساوٍ، و`reconcile` = 0.

### 6.3 خارج نطاق هذه الخطة لكنه معتمد عليها (يُسلَّم لأصحابه)

- اختبارات العكس وقفل الفترة ورفض القيد غير المتوازن (05-عالي-5) → مخطط المحاسبة.
- إصلاح `command_resolve_dispute` لقيد الخصم (05-عالي-3) → مخطط المحاسبة.
- مزامنة الموبايل لأرصدة العملات و`currencyBreakdown` في البطاقة الرئيسية (06-عالي-8/9) → مخطط الموبايل.

---

## 7. المخاطر والأسئلة المفتوحة

1. **عقد RPC مشترك:** توقيع `create_ledger_entry` النهائي يجب تثبيته بالتنسيق مع مخطط عقد API/الموبايل قبل خطوة 9 — أي انحراف في اسم معامل يعيد كسر PGRST202.
2. **`p_source_device_id`:** الموبايل لا يرسله حالياً في الحمولة المرجعية؛ إن قرر مخطط العقد إبقاءه في التوقيع العام يُضاف كمعامل أخير اختياري (uuid).
3. **الرادع الدفاعي على `customer_currency_balances`** (3.3): آلية `set_config` تحتاج اختباراً دقيقاً؛ إن تعذرت يُكتفى بسحب المنح — القرار للمنفذ مع اختبار 17.
4. **`credit_limit` لكل عملة** قرار عملي قابل للجدل (التاجر يفكر بعملة واحدة غالباً)؛ موثق كمسلّمة في قسم 1 وقابل للمراجعة في المرحلة 1.
5. **السيناريو ج مستحيل نظرياً** لكن كتلة التنظيف تجعل الخطة محصنة ضده بلا كلفة إضافية.

---

*انتهت الخطة — لم يُعدَّل أي ملف في المشروع سوى إنشاء هذا الملف.*
