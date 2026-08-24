# خطة إصلاح السلامة المالية والتزامن — مخطط_السلامة_المالية_والتزامن

**النطاق:** باكند `debt-ledger-supabase` — أوامر القيود المالية، العكس، النزاعات ذات الأثر المالي، كشوف الحساب، idempotency، مصدر الحقيقة للأرصدة، والتسوية.

**المصادر المقروءة فعلياً:**
- `analysis-reports/02-functions-logic.md` (ملاحظات 4، 5، 7، 9، 10، 11، 13، 14، 16، 19)
- `analysis-reports/05-double-entry.md` (ملاحظات 3، 4، 5، 6، 7، 8)
- `final-audit-report.md` (البنود H1، H2، H3، H6، H14، H15، H16، H39، H41)
- `supabase/migrations/202607120002_functions_and_triggers.sql` (685 سطراً)
- `supabase/migrations/202608140006_platform_hardening_and_offline.sql` (566 سطراً)
- `supabase/migrations/202608140008_member_invites_and_statement_commands.sql` (219 سطراً)
- `supabase/migrations/202608140010_double_entry_accounting.sql` (515 سطراً)
- `supabase/migrations/202608140011_accounting_command_receipts.sql` (12 سطراً)
- `supabase/functions/generate-statement/index.ts` (الأسطر 422–532: يستدعي RPC `create_statement` ثم يبني PDF من `statements`/`statement_items`)
- `docs/double-entry-accounting-spec.md:88-91`، `docs/api-reference-and-operational-flow.md:188,271-274`، واختبارات `tests/database/002,003`

**افتراضات وحدود النطاق:**
1. الترحيل `202608180012_multi_currency_and_categories.sql` سيُحذف أو يُعاد كتابته ضمن خطة المخطط (خطة أخرى) — هذه الخطة تفترض **عملة واحدة لكل محل** كما يفرضها `validate_ledger_entry_insert` (0010:329-330). جدول `customer_currency_balances` خارج النطاق.
2. إصلاح عقد RPC مع تطبيق Flutter (أسماء `command_*` ومعاملات `p_currency_code` الزائدة) مملوك لخطة عقد API — لكن أي تغيير توقيع هنا (إضافة `p_client_request_id`) موثق في كل خطوة ليتزامن معها.
3. كل التغييرات تُنفذ في **ترحيلات جديدة** (`2026xxxx0013_...` وما بعده) — لا يُعدَّل أي ترحيل قائم.

---

## أولاً: القرارات المعمارية المحسومة

### D1 — نمط القفل الموحد: ترتيب أقفال ثابت لكل الأوامر المالية

**المشكلة:** `command_create_ledger_entry` يُسلسل بقفل صف `business_customers` (0006:267)، بينما `command_reverse_ledger_entry` يقفل صف `ledger_entries` فقط (0006:314) — قفلان مختلفان يسمحان بتسابق «سداد + عكس» = رصيد سالب −100 رغم نجاح كل فحص منفرداً (تقرير 02، ملاحظة 4).

**الخيارات:**
- **(أ) قفل صف `business_customers` كنقطة تسلسل لكل أمر يمس رصيد عميل** — صف واحد لكل (محل، عميل)، موجود دائماً، وهو أصلاً نقطة التسلسل في مسار الإنشاء.
- **(ب) قفل استشاري `pg_advisory_xact_lock` مفتاحه `business_customer_id`** — يعمل، لكنه يفقد دلالة الصف نفسه (فحص `is_archived` وقراءة `credit_limit`) ويتطلب انضباطاً يدوياً كاملاً بلا حماية قاعدة البيانات الطبيعية.
- **(ج) مستوى عزل SERIALIZABLE لكل الأوامر** — يلغي التسابق لكنه يفرض إعادة محاولة على أخطاء `40001` في كل عميل (Flutter + Edge Functions)، وتكلفته على العبء غير مبررة الآن.

**التوصية: (أ)** مع ترتيب أقفال إلزامي موحد لمنع deadlock، يُطبق حرفياً في كل دالة `private.command_*`:

```
الترتيب الإلزامي (من الأعم للأخص):
  1. قفل استشاري على مفتاح idempotency:  pg_advisory_xact_lock(hashtextextended(p_client_request_id::text, 0))
     — يُسلسل إعادات إرسال نفس الأمر تحت تزامن حقيقي (يعالج 23505 الخام، تقرير 02 ملاحظة 19).
  2. قفل صف business_customers:          select ... from public.business_customers where id = $1 for update
     — نقطة التسلسل لكل ما يمس رصيد العميل (إنشاء، خصم، عكس، كشف).
  3. قفل صف ledger_entries الأصلي:        select ... from public.ledger_entries where id = $1 for update
     — للعكس والنزاع فقط، وبعد الخطوة 2 دائماً.
  4. قفل استشاري على القيد لدورة النزاع:  pg_advisory_xact_lock(hashtextextended(p_entry_id::text, 0))
     — مشترك بين open_dispute وconfirm_ledger_entry وreverse_ledger_entry.
```

**قاعدة صارمة:** ممنوع قفل `ledger_entries` قبل `business_customers` في أي مسار. بما أن `command_resolve_dispute` يستدعي `command_reverse_ledger_entry` داخلياً (0006:461)، فالدوال المركبة ترث الترتيب تلقائياً لأن العكس هو أول من يلمس القيد بعد قفل العميل.

SQL توضيحي لأمر العكس بعد الإصلاح (يستبدل 0006:302-336):

```sql
create or replace function private.command_reverse_ledger_entry(
  p_entry_id uuid, p_reason text, p_client_request_id uuid default gen_random_uuid()
) returns uuid language plpgsql security definer set search_path='' as $$
declare
  v_original public.ledger_entries%rowtype;
  v_bc public.business_customers%rowtype;
  v_balance numeric(20,4); v_allow_credit boolean;
  v_id uuid; v_direction public.ledger_direction;
  v_request_id uuid := coalesce(p_client_request_id, gen_random_uuid());
begin
  -- (1) تسلسل إعادات الإرسال
  perform pg_advisory_xact_lock(hashtextextended(v_request_id::text, 0));
  -- قراءة أولية بلا قفل لمعرفة العميل
  select * into v_original from public.ledger_entries where id = p_entry_id;
  if not found or v_original.entry_type = 'reversal' then raise exception 'Invalid original entry'; end if;
  -- (2) قفل صف العميل أولاً — نفس نقطة تسلسل الإنشاء
  select * into v_bc from public.business_customers where id = v_original.business_customer_id for update;
  -- (3) ثم قفل القيد الأصلي
  select * into v_original from public.ledger_entries where id = p_entry_id for update;
  -- (4) قفل دورة النزاع المشترك
  perform pg_advisory_xact_lock(hashtextextended(p_entry_id::text, 0));
  if not private.is_business_member(v_original.business_id,
      array['owner','admin','accountant']::public.business_role[]) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  -- idempotency بعد الأقفال
  select id into v_id from public.ledger_entries
   where business_id = v_original.business_id and client_request_id = v_request_id;
  if v_id is not null then return v_id; end if;
  if exists(select 1 from public.ledger_entries where reversal_of_entry_id = p_entry_id) then
    raise exception 'Entry already reversed';
  end if;
  -- منع العكس أثناء نزاع نشط (تقرير 02 ملاحظة 11)
  if exists(select 1 from public.disputes d join public.dispute_state ds on ds.dispute_id = d.id
            where d.entry_id = p_entry_id
              and ds.status in ('open','awaiting_merchant','awaiting_customer','escalated')) then
    raise exception 'Entry has an active dispute; resolve it first';
  end if;
  -- فحص الرصيد عند عكس قيد مدين: العكس يطرح من الرصيد (تقرير 02 ملاحظة 4)
  if v_original.direction = 'debit' then
    select coalesce(sum(case when direction='debit' then amount else -amount end),0)
      into v_balance from public.ledger_entries
     where business_customer_id = v_original.business_customer_id;
    select allow_customer_credit_balance into v_allow_credit
      from public.business_accounting_settings where business_id = v_original.business_id;
    if v_balance - v_original.amount < 0 and not coalesce(v_allow_credit, true) then
      raise exception 'Reversal would push the customer balance below zero';
    end if;
  end if;
  v_direction := case when v_original.direction = 'debit' then 'credit' else 'debit' end;
  insert into public.ledger_entries(/* ... كما في 0006:324-330 ... */);
  insert into public.command_receipts(/* ... كما في 0006:331-333 ... */);
  return v_id;
end $$;
```

### D2 — كشف الحساب: قفل صفوف ضمن نمط D1 (وليس رفع مستوى العزل)

**المشكلة:** `command_create_statement` (0008:152-180) يحسب الرصيد الافتتاحي ثم المجاميع ثم البنود في ثلاثة استعلامات بلا قفل — قيد رجعي (`occurred_at` مسموح بلا حدود) بينها يكسر تطابق `closing_balance` مع مجموع `statement_items` في وثيقة «موقعة» (تقرير 02 ملاحظة 7، H3).

**الخيارات:**
- **(أ) قفل صف(وف) `business_customers` وفق نمط D1:** نطاق `business_customer` يقفل صفاً واحداً؛ نطاق `customer_consolidated` يقفل كل صفوف العميل **مرتبة بـ `id`** (`select id ... order by id for update`) لمنع deadlock بين كشفين متزامنين. يعمل تحت `READ COMMITTED` الافتراضي في PostgREST بلا أي تغيير بنية تحتية.
- **(ب) `set_config('transaction_isolation','repeatable read',true)` كأول سطر في الدالة:** لقطة متسقة بلا حجب الكُتّاب، لكنه هش (يجب أن يسبق أي استعلام في المعاملة)، ويصعب ضمانه عبر PostgREST، ولا يمنح idempotency.

**التوصية: (أ)** — آلية واحدة مفهومة للفريق (نفس نمط D1)، وحجب الكتابة مقبول لأن توليد الكشف قصير (الـ PDF يُبنى لاحقاً في `generate-statement` خارج المعاملة، `index.ts:446-532`). يُضاف لاحقاً `p_client_request_id` + receipt (انظر S7) فيعالج تكرار الكشوفات.

### D3 — مصدر الحقيقة للرصيد: `ledger_entries` تشغيلياً + تسوية آلية مع الدفتر العام

**المشكلة:** رصيد العميل يُحسب من `ledger_entries` (`business_customer_balances` 0002:653-670 و`business_customer_account_positions` 0010:479-490) بينما ميزان المراجعة يحسب من `journal_entry_lines` — مصدران بلا أي آلية تسوية تكشف الانحراف (تقرير 05 ملاحظة 6).

**الخيارات:**
- **(أ) الدفتر التشغيلي مصدر الحقيقة للرصيد التشغيلي، والدفتر العام مرآة محاسبية مضمونة بذرّية التريجر (0010:301-312)، مع تسوية دورية تكشف أي انحراف.**
- **(ب) اشتقاق رصيد العميل من أسطر الدفتر العام (1100) مباشرة** — يفقد الأبعاد التشغيلية (`due_date`، التأكيد، النزاع) ويبطئ الاستعلامات، ولا يلغي الحاجة لتسوية بالاتجاه المعاكس.

**التوصية: (أ)** — توثيق القرار صراحة في `double-entry-accounting-spec.md` («رصيد العميل التشغيلي يُشتق من `ledger_entries`؛ حساب 1100 في الدفتر العام مرآته المحاسبية؛ أي انحراف يُكشف آلياً خلال 24 ساعة»)، وبناء عرض تسوية + وظيفة دورية (S9، S12).

### D4 — سياسة «الدفع الأكبر من الرصيد»: السماح افتراضياً (رصيد دائن «له مبلغ»)

**المشكلة:** `First-version.md:1037-1043` يقرر المنع، بينما التنفيذ يسمح (`allow_customer_credit_balance default true`، 0010:39,366-367) والاختبار `003:33` يختبر دفعة 230 مقابل رصيد 180 كسلفة، والوثيقتان المرجعيتان الحديثتان توثقان السماح (`double-entry-accounting-spec.md:89`، `api-reference-and-operational-flow.md:188,272`) — H41.

**التوصية:** **اعتماد السماح** كقرار منتج نهائي: السيناريو التجاري (دفعة مقدمة/سلفة) حقيقي في السوق المستهدف، والتنفيذ والاختبار والوثائق الحديثة كلها عليه. الإجراء: تحديث `First-version.md:1037-1043` ليطابق، إبقاء المفتاح لكل محل (`allow_customer_credit_balance`)، وإخضاع **عكس القيد المدين** لنفس المفتاح (S1) حتى لا يكون العكس ثغرة خلفية لنفس السياسة، وإظهار «له مبلغ» في الواجهة (S14).

### D5 — حالة `voided`: إزالتها من الـ enum (الإبطال بالعكس فقط)

**المشكلة:** `journal_entry_status` يعرف `'voided'` (0010:10) لكن `trg_journal_entries_immutable` (0010:121-124) يمنع أي UPDATE — قيمة ميتة، وميزان المراجعة (0010:465-477) لا يرشّح بالحالة فتتلوث الأرصدة لو وُجدت مستقبلاً (H6).

**الخيارات:** (أ) بناء مسار إبطال حقيقي (دالة void + استثناء في تريجر المنع)؛ (ب) إزالة `'voided'` من الـ enum وترشيح ميزان المراجعة بـ `status='posted'`.
**التوصية: (ب)** — الممارسة المحاسبية السليمة (والموثقة في التقرير 05 إيجابي 3) هي التصحيح بقيد عكسي فقط؛ وجود مسار void ثانٍ يضيف سطح خطأ بلا قيمة.

### D6 — حد الوصف 500 حرف: الاقتطاع عند البناء (لا رفع الحد)

**المشكلة:** `post_ledger_entry_journal` يبني `'Ledger entry '||type||': '||description` (0010:260) — بادئة حتى 30 حرفاً + وصف حتى 500 مقابل حد 500 في `journal_entries.description` (0010:68) → سقوط العملية كلها (H15). ونفس الخلل في وصف عكس النزاع `'تصحيح بسبب اعتراض: '||note` (0006:461، تقرير 02 ملاحظة 16).

**التوصية:** `left(..., 500)` في موضعي البناء الاثنين — يحفظ عقد قاعدة البيانات، والبادئة التقنية لا تستحق مساحة من نص المستخدم.

---

## ثانياً: خطوات التنفيذ

> كل خطوة تُنفذ في ترحيل جديد. التسمية المقترحة: `202609010013_financial_locking_and_receipts.sql` (S1، S2، S4، S5، S6، S8)، `202609020014_statement_consistency.sql` (S7)، `202609030015_ar_reconciliation.sql` (S9، S12).

### [فوري — خلال 24 ساعة]

**S1 — إصلاح تسابق العكس (قفل العميل + فحص النزاع + فحص الرصيد)** — H1
- **الملف المستهدف:** ترحيل `0013` — إعادة تعريف `private.command_reverse_ledger_entry` (النافذة حالياً 0006:302-336).
- **التغيير:** تطبيق SQL الموضح في D1 حرفياً: قفل idempotency الاستشاري ← قفل `business_customers ... for update` ← قفل القيد ← قفل النزاع الاستشاري؛ فحص النزاع النشط؛ فحص رصيد عند عكس قيد مدين مربوط بـ `allow_customer_credit_balance`.
- **معيار التحقق:** اختبار التزامن C1 (سداد + عكس متزامنان) لا ينتج رصيداً سالباً مخالفاً للسياسة؛ pgTAP: عكس دين مسدد بالكامل مع `allow_customer_credit_balance=false` يُرفض، ومع `=true` ينجح ويظهر في `amount_business_owes_customer`؛ العكس أثناء نزاع نشط يُرفض برسالة واضحة.
- **الاعتماديات:** D4 (السياسة)، لا اعتمادية على خطوات أخرى.
- **الجهد:** 0.5 يوم.

**S2 — إصلاح قبول النزاع الجزئي على قيد خصم** — H14
- **الملف المستهدف:** ترحيل `0013` — إعادة تعريف `private.command_resolve_dispute` (النافذة 0006:433-484)، تحديداً الأسطر 463-468.
- **التغيير:** تفريع صريح عند `partially_accepted`: إن كان `v_entry.entry_type='discount'` يُستدعى `private.command_apply_customer_discount(v_entry.business_customer_id, p_corrected_amount, ...)` بدل `command_create_ledger_entry` الذي يرفض `discount` (0010:356). الأدوار متوافقة (الإغلاق يتطلب owner/admin/accountant وهي نفسها أدوار الخصم). إضافة: رفض `p_corrected_amount` صراحة عند `rejected` (تقرير 02 ملاحظة 15)، وإرجاع `v_reversal` عند `accepted` و`null` موثق عند `rejected`.
- **معيار التحقق:** pgTAP: نزاع على قيد `discount` يُحل `partially_accepted` بنجاح ويولد قيد خصم مصححاً بقيد يومية متوازن (مدين 5100/دائن 1100)؛ الرصيد النهائي = الأصلي − المصحح.
- **الاعتماديات:** S1 (لأن الإغلاق يستدعي العكس داخلياً — يرث قفله الجديد).
- **الجهد:** 0.5 يوم.

**S3 — حسم السياسات المعلقة وتوثيقها** — H41، H6
- **الملف المستهدف:** `docs/First-version.md:1037-1043` (تحديث المنع → السماح الافتراضي مع مفتاح لكل محل)؛ `docs/double-entry-accounting-spec.md` (إضافة فقرة «قرارات محسومة»: D3 مصدر الحقيقة، D4 الدفع الزائد، D5 الإبطال بالعكس فقط، D6 اقتطاع الوصف)؛ `docs/api-reference-and-operational-flow.md` (توثيق سلوك العكس عند الرصيد السالب).
- **التغيير:** توثيق فقط — لا كود.
- **معيار التحقق:** لا يبقى أي تناقص نصي بين الوثائق الثلاث والتنفيذ؛ مراجعة مدقق الوثائق (خطة 09) تقبل.
- **الاعتماديات:** قرار معماري من قائد الفريق على D4 (التوصية: السماح).
- **الجهد:** 0.5 يوم.

**S4 — اقتطاع وصف القيد اليومي عند 500 حرف** — H15
- **الملف المستهدف:** ترحيل `0013` — إعادة تعريف `private.post_ledger_entry_journal` (0010:239-299) السطر 260، و`private.command_resolve_dispute` السطر 461.
- **التغيير:** `left('Ledger entry '||v_entry.entry_type::text||': '||v_entry.description, 500)` و`left('تصحيح بسبب اعتراض: '||trim(p_resolution_note), 500)`.
- **معيار التحقق:** pgTAP: قيد بوصف 500 حرف ينجح ويولد قيد يومية (كان يسقط بانتهاك check)؛ نزاع بملاحظة 490 حرفاً يُغلق بنجاح.
- **الاعتماديات:** لا شيء.
- **الجهد:** ساعة واحدة.

### [مرحلة صفر — يحظر الإطلاق]

**S5 — استكمال نمط القفل في التأكيد والنزاع** — تقرير 02 ملاحظة 13
- **الملف المستهدف:** ترحيل `0013` — إعادة تعريف `private.command_confirm_ledger_entry` (0006:339-359) و`private.command_open_dispute` (0006:361-387).
- **التغيير:** (1) التأكيد يأخذ نفس القفل الاستشاري `pg_advisory_xact_lock(hashtextextended(p_entry_id::text,0))` الذي يأخذه فتح النزاع (0006:372) — فيستحيل «مؤكد ومتنازع عليه» معاً؛ (2) التأكيد يفحص `ledger_entry_state.is_reversed` ويرفض تأكيد قيد معكوس؛ (3) فتح النزاع يفحص غياب تأكيد سابق وغياب عكس سابق.
- **معيار التحقق:** اختبار التزامن C4: تأكيد + فتح نزاع متزامنان → واحد فقط ينجح؛ pgTAP: تأكيد قيد معكوس يُرفض.
- **الاعتماديات:** S1 (ترتيب الأقفال الموحد).
- **الجهد:** 1 يوم.

**S6 — تعميم command_receipts على الأوامر الثمانية كاملة** — H2، تقرير 05 ملاحظة 7
- **الملف المستهدف:** ترحيل `0013` — إعادة تعريف: `command_confirm_ledger_entry`، `command_open_dispute`، `command_add_dispute_message` (0006:389-431)، `command_resolve_dispute`، `command_post_manual_journal` (0010:410-436) + أغلفتها العامة في `public`.
- **التغيير:** لكل أمر: (1) معامل جديد `p_client_request_id uuid default null`؛ (2) أول سطر: قفل استشاري على المفتاح (نمط D1 خطوة 1)؛ (3) بعد الأقفال: `select result_entity_id from public.command_receipts where idempotency_key = v_request_id` → إن وُجد يُعاد مباشرة؛ (4) قبل الإرجاع: إدراج الإيصال `on conflict do nothing`. لـ `post_manual_journal`: إضافة المعامل للتوقيعين العام والخاص (يُنسَّق مع خطة عقد API لأن التطبيق لا يرسله اليوم — `default null` يبقي التوافق). الإيصال يخزن `result` كافياً لإعادة الرد (مثلاً `dispute_id`، `confirmation_id`، `journal_entry_id`).
- **معيار التحقق:** pgTAP لكل أمر من الثمانية: تنفيذه مرتين بنفس `client_request_id` يعيد نفس المعرف ولا يكرر الأثر (لا قيد ثانٍ، لا نزاع ثانٍ، لا رسالة ثانية)؛ اختبار التزامن C2 وC6.
- **الاعتماديات:** S1، S5 (الأقفال يجب أن تسبق فحص الإيصال).
- **الجهد:** 1.5 يوم.

**S7 — كشف الحساب: معاملة متسقة + idempotency** — H3
- **الملف المستهدف:** ترحيل `0014` — إعادة تعريف `private.command_create_statement` (0008:115-183) وغلافه `public.create_statement`؛ توسيع check في `command_receipts` (0011:5-10) بنوع تاسع `'create_statement'`.
- **التغيير:** (1) بعد فحوص الصلاحية: نطاق `business_customer` → `select ... from public.business_customers where id=p_business_customer_id for update`؛ نطاق `customer_consolidated` → `perform 1 from public.business_customers where customer_id=v_customer order by id for update` (ترتيب ثابت ضد deadlock)؛ (2) معامل `p_client_request_id uuid default null` + قفل استشاري عليه + فحص إيصال يعيد `statement_id` المخزن؛ (3) إدراج الإيصال بنوع `create_statement`؛ (4) توثيق أن الكشف «لقطة حتى لحظة القفل» — قيد رجعي لاحق لا يعدّل كشفاً صادراً (يتطلب كشفاً جديداً)، وهذا سلوك مقصود يُذكر في `api-reference`.
- **معيار التحقق:** اختبار التزامن C3: توليد كشف متزامن مع إدراج قيد رجعي → `opening + debits − credits = closing` **و** يساوي مجموع بنوده دائماً؛ pgTAP: نفس المفتاح مرتين → نفس الكشف، لا كشف مكرر برمز تحقق جديد.
- **الاعتماديات:** S1 (النمط)، S6 (بنية الإيصالات).
- **الجهد:** 1 يوم.

**S8 — حسم `voided` تقنياً: إزالة القيمة + ترشيح ميزان المراجعة** — H6
- **الملف المستهدف:** ترحيل `0013` — `alter type public.journal_entry_status remove value 'voided'` (يتطلب إعادة إنشاء النوع لأن PostgreSQL لا يدعم حذف قيمة enum مباشرة: إنشاء نوع جديد ← `alter column ... type` ← حذف القديم)؛ إعادة تعريف العرض `public.account_trial_balance` (0010:465-477) بانضمام `join public.journal_entries je on je.id=jel.journal_entry_id and je.status='posted'`.
- **التغيير:** كما أعلاه؛ التحقق المسبق أن لا صفوف بـ `status='voided'` في الإنتاج (فحص `do $$ ... $$` يفشل الترحيل إن وُجدت).
- **معيار التحقق:** pgTAP: ميزان المراجعة لا يتغير قبل/بعد؛ النوع لا يقبل `'voided'`؛ `pgTAP hasnt_enum_value` مكافئ.
- **الاعتماديات:** S3 (القرار الموثق).
- **الجهد:** 0.5 يوم.

**S9 — عرض التسوية الآلية بين الدفتر التشغيلي والدفتر العام** — تقرير 05 ملاحظة 6
- **الملف المستهدف:** ترحيل `0015` — عرض جديد `public.reconciliation_customer_ar` + دالة `private.run_ar_reconciliation() returns integer`.
- **التغيير:** العرض يقارن لكل `business_customer_id`: الرصيد الموقع من `ledger_entries` (كما في 0010:484) مقابل مجموع أسطر الدفتر العام على حساب العملاء الضابط لنفس العميل:

```sql
create view public.reconciliation_customer_ar with (security_invoker=true) as
select bc.id as business_customer_id, bc.business_id,
  coalesce((select sum(case when le.direction='debit' then le.amount else -le.amount end)
            from public.ledger_entries le where le.business_customer_id=bc.id),0)::numeric(20,4) as operational_balance,
  coalesce((select sum(jel.debit_amount)-sum(jel.credit_amount)
            from public.journal_entry_lines jel
            join public.journal_entries je on je.id=jel.journal_entry_id and je.status='posted'
            join public.business_accounting_settings s
              on s.business_id=bc.business_id and s.accounts_receivable_account_id=jel.account_id
            where jel.business_customer_id=bc.id),0)::numeric(20,4) as gl_ar_balance
from public.business_customers bc;
-- الانحراف = حيث operational_balance <> gl_ar_balance
```

  الدالة `run_ar_reconciliation()` تحسب الانحرافات وتدرج كل انحراف في `private.dead_letter_jobs` (`job_type='ar_reconciliation'`، `source_id=business_customer_id::text`) مع `on conflict do update`، وتعيد عدد الانحرافات.
- **معيار التحقق:** على بيانات سليمة العرض بلا انحرافات (بما فيها بيانات الاختبار 003: الرصيد −50 يطابق GL)؛ pgTAP يحقن انحرافاً اصطناعياً (تحديث مباشر بـ service) فيكشفه العرض والدالة.
- **الاعتماديات:** S8 (ترشيح `status='posted'`).
- **الجهد:** 1 يوم.

**S10 — اختبارات pgTAP السلبية والمحاسبية الناقصة** — H16
- **الملف المستهدف:** `supabase/tests/database/004_financial_integrity.sql` (جديد).
- **التغيير:** `plan(...)` يغطي: (1) عكس دين يصفّر رصيده في GL (أسطر معكوسة، 0010:263-274)؛ (2) `throws_ok` لعكس العكس (0010:338) وللعكس المزدوج؛ (3) `throws_ok` لقيد يدوي غير متوازن (tريجر 0010:219-221)؛ (4) `throws_ok` للترحيل في فترة مقفلة (0010:167-176) بعد `close_accounting_period`؛ (5) `throws_ok` لتحديث/حذف `journal_entries` (0010:121-124)؛ (6) `throws_ok` لخصم يتجاوز الرصيد (0010:393)؛ (7) سياسة الدفع الزائد: مع `allow_customer_credit_balance=false` دفعة زائدة تُرفض، ومع `=true` تنجح وتظهر «له مبلغ»؛ (8) سيناريوهات S1/S2/S4 أعلاه.
- **معيار التحقق:** `supabase test db` أخضر بالكامل؛ كل `throws_ok` يثبت رفضاً فعلياً لا مجرد نجاح مسار سعيد.
- **الاعتماديات:** S1، S2، S4، S8.
- **الجهد:** 1.5 يوم.

**S11 — حزام اختبارات التزامن** — H39، تفصيل في «ثالثاً» أدناه
- **الملف المستهدف:** `supabase/tests/concurrency/` (جديد): سكربت `run.sh` + ملفات SQL لكل سيناريو، يُشغّل جلسات `psql` متوازية على قاعدة اختبار محلية.
- **معيار التحقق:** السيناريوهات C1–C6 الستة تمر 20 تكراراً متتالياً بلا انحراف؛ يُربط بـ CI في خطة الاختبارات.
- **الاعتماديات:** S1، S5، S6، S7.
- **الجهد:** 2 يوم.

### [مرحلة 1 — تجريبي مغلق]

**S12 — جدولة التسوية اليومية وتنبيه المالك**
- **الملف المستهدف:** ترحيل `0015` — `cron.schedule('ar-reconciliation-daily','17 3 * * *','select private.run_ar_reconciliation();')` (دقيقة خارج الذروة)؛ عند وجود انحرافات: `enqueue_notification` لمالك المحل.
- **معيار التحقق:** وظيفة مجدولة تظهر في `cron.job`؛ حقن انحراف في بيئة التجريبي يولد تنبيهاً خلال دورة واحدة.
- **الاعتماديات:** S9.
- **الجهد:** 0.5 يوم.

**S13 — تغطية التدقيق للأحداث المحاسبية الجوهرية** — تقرير 02 ملاحظة 12
- **الملف المستهدف:** ترحيل `0015` — ربط `audit_row_change` (0005:37-43) على `accounting_periods` و`chart_of_accounts` و`journal_entries` (إدراج فقط).
- **معيار التحقق:** pgTAP: إغلاق فترة يترك صفاً في سجل التدقيق.
- **الاعتماديات:** لا شيء.
- **الجهد:** 0.5 يوم.

**S14 — إظهار سياسة الرصيد الدائن في الواجهة والوثائق التشغيلية**
- **الملف المستهدف:** تنسيق مع خطة الموبايل: عرض `amount_business_owes_customer` («له مبلغ») في شاشة العميل، وتحذير عند تسجيل دفعة تتجاوز الرصيد؛ تحديث `api-reference-and-operational-flow.md` بسلوك العكس الجديد (S1).
- **معيار التحقق:** مراجعة UX + لقطة شاشة في التجريبي المغلق.
- **الاعتماديات:** S1، D4، خطة الموبايل.
- **الجهد:** 0.5 يوم (حصة الباكند فقط).

### [مرحلة 2 — إطلاق تجاري]

**S15 — تحسينات أداء التريجرات المالية**
- **الملف المستهدف:** ترحيل جديد — تحويل `trg_journal_entry_balanced` (0010:219-221) من `for each row` إلى `for each statement` مع جدول انتقال (transition table) — تقرير 05 ملاحظة 11؛ تقييم فهرس مركب `ledger_entries(business_customer_id, direction)` لتسريع حسابات الرصيد المتكررة (0006:280، 0010:365،392).
- **معيار التحقق:** معيار أداء: توليد كشف 10k قيد < 2 ثانية؛ كل اختبارات 003/004 تبقى خضراء.
- **الاعتماديات:** مرحلة صفر كاملة.
- **الجهد:** 1 يوم.

**S16 — تقييم SERIALIZABLE للأوامر الحرجة (قرار مؤجل موثق)**
- **الملف المستهدف:** وثيقة قرار في `docs/` + (اختيارياً) منطق إعادة محاولة `40001` في عميل المزامنة.
- **التغيير:** بعد بيانات عبء التجريبي: إن ظهرت حاجة لضمانات أقوى من D1 (مثلاً تحليلات مالية عتاريخية ثقيلة)، يُقيَّم رفع `command_create_statement` وحدها إلى `repeatable read` عبر `set_config` كأول سطر (خيار D2-ب) أو SERIALIZABLE مع إعادة محاولة.
- **معيار التحقق:** وثيقة قرار معتمدة؛ إن طُبق: اختبار C3 يمر تحت العزل الجديد.
- **الاعتماديات:** بيانات استخدام مرحلة 1.
- **الجهد:** 1 يوم.

---

## ثالثاً: اختبارات التزامن المطلوبة (S11)

حزام `supabase/tests/concurrency/`: سكربت يفتح جلستي `psql` (أو أكثر) في آنٍ على قاعدة اختبار، مع `pg_sleep` مدروس لتعظيم التداخل، ويتحقق من الحالة النهائية:

| # | السيناريو | الإعداد | التحقق |
|---|---|---|---|
| C1 | سداد + عكس متزامنان على نفس العميل | رصيد 100 (دين 100)؛ TX1 سداد 100، TX2 عكس الدين — يبدآن معاً | الرصيد النهائي ∈ {0, −100 حسب السياسة} و**لا ينتج** من نجاح فحصين متداخلين؛ مع `allow_customer_credit_balance=false` أحدهما يُرفض حتماً |
| C2 | نفس `client_request_id` من جلستين متزامنتين (إنشاء/عكس/خصم) | إطلاق الأمر مرتين في اللحظة نفسها | قيد واحد بالضبط، إيصال واحد، كلا النداءين يعيدان نفس المعرف — لا `23505` خام |
| C3 | توليد كشف متزامن مع إدراج قيد رجعي | TX1 `create_statement` لفترة، TX2 إدراج قيد بـ `occurred_at` داخل الفترة | `opening+debits−credits=closing` ويساوي مجموع `statement_items` — القيد إما داخل اللقطة كاملاً أو خارجها كاملاً |
| C4 | تأكيد + فتح نزاع متزامنان على نفس القيد | عميل مرتبط، جلستان | واحد فقط ينجح؛ لا حالة «مؤكد ومتنازع عليه» |
| C5 | عكسان متزامنان لنفس القيد | جلستان `reverse_ledger_entry` | واحد ينجح؛ الثاني «Entry already reversed» أو رد idempotent إن شاركا المفتاح |
| C6 | قيدان يدويان بنفس `client_request_id` متزامنان | جلستان `post_manual_journal` | قيد يومية واحد بالضبط |

**ملاحظة تنفيذية:** pgTAP وحده لا يولد تزامناً حقيقياً — لذلك الحزام سكربت shell/psql خارجي، ويُستدعى من CI بعد `supabase test db` (التنسيق مع خطة الاختبارات/CI).

---

## رابعاً: المخاطر والملاحظات

1. **تغيير تواقيع الدوال العامة** (S6، S7): إضافة معاملات بقيم افتراضية متوافقة رجعياً لاستدعاءات SQL، لكن PostgREST يطابق التوقيع بالاسم — يجب تنسيق يوم النشر مع خطة عقد API/الموبايل (التطبيق يستدعي أسماء خاطئة أصلاً اليوم، فيُصلحان معاً).
2. **إعادة تعريف `command_reverse_ledger_entry` تؤثر على `command_resolve_dispute`** الذي يستدعيها داخلياً (0006:461) — اختبارات S10 تغطي المسارين معاً، وترتيب الترحيل داخل `0013` يضمن تعريف العكس قبل الإغلاق.
3. **قفل الكشف الموحد (S7)** يحجب كتابة قيود العميل أثناء التوليد — مقبول لأن التوليد قصير وPDF خارجه؛ يُراقب زمن التنفيذ في التجريبي (S15 إن لزم).
4. **خارج النطاق عمداً:** تعدد العملات، مشغل `customer_currency_balances`، عقد RPC مع Flutter، PDF العربي في `generate-statement` — كلها مملوكة لخطط أخرى ومذكورة هنا كاعتماديات فقط.

---

**ملخص التوزيع:** 16 خطوة — فوري 4 (S1–S4) · مرحلة صفر 7 (S5–S11) · مرحلة 1 ثلاث (S12–S14) · مرحلة 2 اثنتان (S15–S16). الجهد الكلي التقديري: ~12 يوم عمل.
