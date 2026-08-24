# تقرير تدقيق المخطط والقيود (Schema & Constraints Audit)

**المدقق:** مدقق_المخطط_والقيود
**النطاق:** `debt-ledger-supabase/supabase/migrations/202607120001_core_schema.sql`، `202608140006_platform_hardening_and_offline.sql`، `202608180012_multi_currency_and_categories.sql`، مقارنةً بـ `debt-ledger-supabase/full_schema.sql` (مع قراءة استكشافية للترحيلات الوسيطة 0002/0009/0010/0011 لأن 0012 يتفاعل معها مباشرة).
**التاريخ:** تنفيذ التدقيق قبل الإطلاق التجاري.

---

## ملخص تنفيذي

المخطط الأساسي (0001–0011) متماسك ومهني: مبالغ `numeric(20,4)` بلا فاصلة عائمة، `timestamptz` في كل مكان، سجل مالي append-only، قيود CHECK شاملة، وفهارس جيدة. **لكن الترحيل الأخير `202608180012_multi_currency_and_categories.sql` مكسور بنيوياً على عدة مستويات: لن يُطبَّق أصلاً (سياسة RLS تستدعي دالة ونوعاً غير موجودين)، ولو طُبِّق جزئياً لعطّل إنشاء القيود المالية بالكامل (مقارنة enum بقيم غير موجودة + مفتاح أجنبي يشير للجدول الخاطئ)، وأدخل دالة عامة موازية بلا أي فحص صلاحيات تكسر عزل المستأجرين وقاعدة "مسار API واحد".** كما أن `full_schema.sql` متوقف عند الترحيل 0011 ولا يعكس 0012.

**إحصائية الملاحظات:** حرج 5 · عالي 5 · متوسط 6 · منخفض 6 · إيجابي 10.

---

## 1. ملاحظات حرجة [حرج]

### 1.1 الترحيل 0012 لن يُطبَّق: دالة ونوع غير موجودين في سياسة RLS
- **الملف:** `supabase/migrations/202608180012_multi_currency_and_categories.sql`، الأسطر 38–43.
- السياسة `customer_currency_balances_select_member` تستدعي `public.has_business_permission(business_id, 'view_balances'::public.business_permission)`.
- بحث شامل في كامل `debt-ledger-supabase` (كل الترحيلات + `full_schema.sql`): لا يوجد أي تعريف للدالة `has_business_permission` ولا للنوع `business_permission` — الظهور الوحيد هو داخل هذا السطر نفسه.
- **الأثر:** `create policy` يفشل بخطأ `function public.has_business_permission(uuid, business_permission) does not exist` → فشل الترحيل بأكمله عند النشر. ولأن الملف بلا `begin/commit` (بخلاف 0001/0006/0010)، فإن نفّذه مقسّماً ستبقى تغييرات جزئية (أعمدة جديدة + جدول بـ RLS مفعّل وبلا سياسات صالحة = رفض ضمني لكل القراءات).

### 1.2 تريجر الأرصدة يقارن enum بقيم غير موجودة → تعطيل كامل لإدراج القيود
- **الملف:** `202608180012_multi_currency_and_categories.sql`، الأسطر 51–111 (خاصة 59 و62).
- الدالة `private.trig_update_customer_currency_balance()` تفحص `if new.direction = 'in'` ثم `else` (أي 'out')، بينما نوع `public.ledger_direction` معرّف في `202607120001_core_schema.sql` سطر 20 بالقيم `('debit','credit')` فقط، ولم يعدّله أي ترحيل لاحق.
- مقارنة عمود enum بقيمة حرفية غير موجودة تؤدي إلى `invalid input value for enum ledger_direction: "in"` عند أول تنفيذ للتريجر.
- **الأثر:** التريجر مربوط `after insert on public.ledger_entries` (أسطر 108–111) → **كل عملية إنشاء قيد مالي في النظام ستفشل**، ومعها تريجر المحاسبة `trg_after_ledger_entry_accounting` (0010 سطر 311). هذا عطل شامل للوظيفة الجوهرية للمنتج.

### 1.3 مفتاح أجنبي يشير إلى الجدول الخاطئ في جدول الأرصدة
- **الملف:** `202608180012_multi_currency_and_categories.sql`، سطر 17.
- `customer_id uuid references public.profiles(id) on delete set null` — بينما التريجر (سطر 82) يدرج فيه `new.customer_id` القادم من `ledger_entries.customer_id` الذي يشير إلى `public.customers(id)` (`202607120001_core_schema.sql` سطر 162).
- `customers.id` و`profiles.id` فضاءا UUID مختلفان (الأول `gen_random_uuid()`، والثاني = `auth.users.id`).
- **الأثر:** حتى لو أُصلحت مشكلة الـ enum، فإن أول إدراج في `ledger_entries` سيفشل بانتهاك مفتاح أجنبي على `customer_currency_balances`. نفس الأثر التعطيلي الشامل.

### 1.4 دالة عامة موازية لإنشاء القيود بلا صلاحيات وبأخطاء نوع متعددة
- **الملف:** `202608180012_multi_currency_and_categories.sql`، الأسطر 114–209: `public.command_create_ledger_entry(...)`.
- المشاكل مجتمعة:
  1. **لا يوجد أي فحص تفويض** — لا `private.is_business_member` ولا أي تحقق أن `auth.uid()` ينتمي للنشاط التجاري. أي مستخدم موثّق يستطيع إنشاء قيود مالية على أي `business_customer_id` في أي متجر → كسر كامل لعزل المستأجرين (multi-tenancy).
  2. `security definer` (سطر 129) **بلا `set search_path = ''`** — بخلاف كل دوال المشروع الأخرى — ما يفتح ثغرة search-path hijacking.
  3. لا يوجد `revoke/grant` → صلاحية `EXECUTE` الافتراضية ممنوحة لدور `PUBLIC`.
  4. تستخدم قيم enum غير موجودة: `'fee'` (سطر 157) ليست ضمن `ledger_entry_type` (0001 سطر 19 + 0009 أضاف 'discount' فقط)، وتسند `'in'/'out'` (أسطر 158–162) لمتغير من نوع `ledger_direction` → خطأ runtime مؤكد.
  5. `p_source_device_id text` (سطر 128) يُدرج في عمود `source_device_id uuid` (0001 سطر 173) → خطأ `column is of type uuid but expression is of type text`.
  6. `p_description text default ''` (سطر 123) يتعارض مع قيد الجدول `check (char_length(trim(description)) between 2 and 500)` (0001 سطر 167) → الاستدعاء بالقيمة الافتراضية يفشل دائماً.
  7. تتجاوز كل ضوابط المسار الأصلي الموجودة في `private.command_create_ledger_entry` (0010 أسطر 346–376): لا قفل `for update`، لا فحص `is_archived`، لا idempotency ناعم (تكرار `client_request_id` يضرب قيد `unique(business_id, client_request_id)` بخطأ بدل الإرجاع السلبي)، لا `command_receipts`، لا فحص حد الائتمان، لا فحص "السداد يتجاوز الرصيد".
- **الأثر:** ثغرة أمنية حرجة + مسارا إنشاء قيود متوازيان، ما يكسر شرط المالك أن كل التواصل يتم عبر API واحد مضبوط.

### 1.5 الدالة الجديدة تخالف قيد CHECK المعدَّل في 0010 بنيوياً
- **الملفات:** `202608140010_double_entry_accounting.sql` أسطر 314–319 مقابل `202608180012` أسطر 157–163.
- القيد `ledger_entries_check` المعدَّل يشترط `direction='debit'` للدين و`direction='credit'` للسداد/الخصم، بينما دالة 0012 تدرج `'in'/'out'`.
- **الأثر:** الترحيلان 0010 و0012 غير متوافقين؛ لا يمكن أن يعملا معاً على نفس قاعدة البيانات. يبدو أن 0012 كُتب ضد نسخة مخطط مختلفة تماماً (اتجاهات in/out، نوع fee، نظام صلاحيات business_permission) لم تصل إلى هذا المستودع.

---

## 2. ملاحظات عالية [عالي]

### 2.1 تضارب مفاهيمي بين 0010 و0012 حول تعدد العملات
- تريجر `private.validate_ledger_entry_insert` (0010 أسطر 321–344، خاصة 329–330) **يفرض** أن عملة أي قيد = عملة النشاط التجاري الواحدة (`businesses.currency_code`) ويرفض غير ذلك.
- بينما 0012 يبني جدول `customer_currency_balances` بمفتاح `(business_customer_id, currency_code)` وكأن العميل سيسجل قيوداً بعدة عملات.
- **الأثر:** مع بقاء قيد 0010، لن يحمل الجدول الجديد إلا صفاً واحداً لكل عميل — ميزة "تعدد العملات" شكلية. يجب حسم القرار المعماري: إما عملة واحدة لكل متجر (وحذف 0012) أو تعدد حقيقي (وتعديل 0010 وطبقة المحاسبة كلها).

### 2.2 سلوك حذف CASCADE في جدول مالي يكسر سياسة RESTRICT المعتمدة
- **الملف:** `202608180012` أسطر 15–16: `on delete cascade` على `business_id` و`business_customer_id`.
- كل الجداول المالية والتنظيمية في 0001 و0010 تستخدم `on delete restrict` عمداً (مثال: 0001 أسطر 160–162، 0010 أسطر 14, 63, 78) لمنع حذف كيانات عليها سجلات مالية.
- **الأثر:** حذف نشاط تجاري أو علاقة عميل سيحذف أرصدة مالية بصمت ودون أثر تدقيقي. و`customer_id ... on delete set null` (سطر 17) يفقد ارتباط الرصيد بصاحبه.

### 2.3 حالة 'voided' في يوميات المحاسبة غير قابلة للوصول
- **الملف:** `202608140010_double_entry_accounting.sql`: النوع `journal_entry_status` يتضمن `'voided'` (سطر 10)، لكن التريجران `trg_journal_entries_immutable` و`trg_journal_entry_lines_immutable` (أسطر 121–124) يمنعان أي UPDATE.
- **الأثر:** لا يمكن إبطال قيد يومية أبداً رغم وجود الحالة في النوع — تناقض تصميمي. الإبطال المحاسبي الصحيح يتطلب إما قيداً عكسياً (reversing journal) أو استثناءً في تريجر المنع لتحديث `status` فقط.

### 2.4 رصيد مشتق قابل للانحراف بلا مصالحة ولا حماية
- `customer_currency_balances` (0012 أسطر 13–26) جدول مشتق (denormalized) يُحدَّث بتريجر فقط، لكنه:
  - بلا تريجر منع تعديل/حذف مباشر (بخلاف `ledger_entry_state` المحمي بسياسات ودالة محددة).
  - بلا أي وظيفة مصالحة (reconciliation) تقارن `current_balance` بمجموع `ledger_entries`.
  - بلا تريجر `set_updated_at` (يُحدَّث يدوياً داخل التريجر فقط).
- **الأثر:** أي انحراف (تعديل يدوي من service_role، خطأ تريجر مستقبلي) يبقى صامتاً إلى الأبد، والواجهة ستعرض رصيداً قد يناقض كشف الحساب الموقّع.

### 2.5 سياسة service_role زائدة ووهم إحساس بالحماية
- **الملف:** `202608180012` أسطر 45–48: سياسة `for all` بشرط `auth.jwt()->>'role' = 'service_role'`.
- `service_role` في Supabase يتجاوز RLS كلياً أصلاً → السياسة ميتة. الخطر أن وجودها يوحي بأن التعديل "محكوم" بينما أي مفتاح service يستطيع التعديل دون قيد، وأي مستخدم عادي ممنوع كلياً (لا سياسة كتابة له) — فمن يصحح انحراف الرصيد؟

---

## 3. ملاحظات متوسطة [متوسط]

### 3.1 `full_schema.sql` غير محدث — يتوقف عند الترحيل 0011
- **الملف:** `debt-ledger-supabase/full_schema.sql` (3070 سطراً) — آخر محتواه هو ترحيل `202608140011_accounting_command_receipts.sql` (الأسطر 3059–3070)، ولا يتضمن أي أثر لـ 0012 (لا `customer_currency_balances` ولا أعمدة category/payment_method).
- **الأثر:** مرجع المخطط الموحّد الذي تعتمد عليه الفرق والاختبارات لا يطابق مسار الترحيلات الفعلي. يجب إعادة توليده بعد حسم مصير 0012، أو توثيق أنه لقطة متعمدة.

### 3.2 أعمدة التصنيف الجديدة نص حر بلا قيود
- **الملف:** `202608180012` أسطر 5–10: `category text default 'goods'` و`payment_method text default 'cash'` بلا `check` ولا enum، بينما المشروع يستخدم enums منضبطة في كل مكان آخر (0001 أسطر 12–32).
- **الأثر:** تشتت قيم التصنيفات ('Goods'، 'GOODS'، 'بضاعة'...) يحبط التقارير والفلاتر.

### 3.3 `attachment_url` مسار مرفقات موازٍ يتجاوز منظومة الملفات
- **الملف:** `202608180012` سطر 10 — يضيف رابط مرفق نصي مباشر على القيد، بينما توجد منظومة كاملة `files` + `ledger_entry_files` + `upload_sessions` مع sha256 وحجم وmime وانتهاء صلاحية (0001 أسطر 257–276، 0006 أسطر 79–93).
- **الأثر:** مساران للمرفقات = فقدان التحقق من السلامة (sha256) وعدم معرفة أي مسار هو المرجعي.

### 3.4 تحويل صامت للعملة غير الصالحة إلى 'YER'
- **الملف:** `202608180012` أسطر 147–150: أي قيمة عملة لا تطابق `^[A-Z]{3}$` تُستبدل بصمت بـ 'YER'.
- **الأثر:** خطأ عميل (أو هجوم) يتحول إلى قيد مالي بعملة خاطئة دون أي إشعار — فساد بيانات صامت. السلوك الصحيح: رفض باستثناء.

### 3.5 `sync_checkpoints.updated_at` بلا تريجر تحديث
- **الملف:** `202608140006_platform_hardening_and_offline.sql` سطر 36 — العمود موجود، لكن تريجرات `set_updated_at` في نفس الملف (أسطر 559–564) تغطي `device_installations` و`business_automation_settings` و`automation_rules` فقط.
- **الأثر:** حقل `updated_at` في جدول مزامنة أساسي يجمد عند قيمة الإنشاء.

### 3.6 قيود اليومية بلا عملة + فترات مفتوحة متداخلة ممكنة
- `journal_entry_lines` (0010 أسطر 76–88) لا تحمل `currency_code` — في بيئة تستهدف تعدد العملات سيجمع `account_trial_balance` (أسطر 465–477) مبالغ بعملات مختلفة في رقم واحد.
- `accounting_periods` (0010 سطر 55) يمنع تكرار نفس (start,end) فقط؛ فحص التداخل موجود فقط في `command_close_accounting_period` (أسطر 452–454) ضد الفترات **المغلقة** — فترتان مفتوحتان متداخلتان ممكنتان.

---

## 4. ملاحظات منخفضة [منخفض]

1. **`statements.currency_code`** (0001 سطر 349): `varchar(3)` بلا قيد regex، بخلاف كل أعمدة العملة الأخرى (أسطر 99، 166).
2. **مفاتيح متعددة الأشكال بلا FK:** `notifications.entity_id` (0001 سطر 306)، `command_receipts.result_entity_id` (0006 سطر 25)، `upload_sessions.entity_id` (0006 سطر 83) — مقبول تصميمياً لكنه يمنع التحقق المرجعي التلقائي.
3. **أعمدة منسوخة في `ledger_entry_events`** (0001 أسطر 198–199): `business_id`/`customer_id` بلا قيد يضمن تطابقهما مع القيد الأب (تُعبأ من الدوال فقط — خطر انحراف منخفض).
4. **رقم سحري مكرر:** حد الملف 10MB (`10485760`) مكرر حرفياً في `files.size_bytes` (0001 سطر 265) و`upload_sessions.expected_size_bytes` (0006 سطر 88) — يستحق ثابتاً مشتركاً أو تعليقاً مترابطاً.
5. **0012 بلا `begin/commit`** بخلاف 0001/0006/0010 — يفاقم خطر الحالة نصف المطبقة عند الفشل (راجع 1.1).
6. **`entry_count integer`** في `customer_currency_balances` (0012 سطر 22): يفضل `bigint` للاتساق مع عدادات الهوية الأخرى، رغم قلة احتمال الفيض.

---

## 5. نقاط إيجابية [إيجابي]

1. **لا فاصلة عائمة إطلاقاً:** كل المبالغ المالية `numeric(20,4)` (0001 أسطر 129, 165, 350–353, 373–375؛ 0010 أسطر 83–84) — دقة كافية للريال اليمني والعملات الكبرى، ولا يوجد أي `float`/`double`/`real` في عمود مالي.
2. **توقيت سليم:** كل الحقول `timestamptz`، مع `date` حيث يلائم (due_date, accounting periods)، وحقل `timezone` نصي على `businesses` (0001 سطر 105) يُستخدم فعلياً في تحويل تاريخ القيد المحاسبي (0010 سطر 254).
3. **سجل مالي append-only حقيقي:** تريجرات `prevent_update_delete` على `ledger_entries, ledger_entry_events, entry_confirmations, disputes, dispute_events, dispute_messages, statement_items` (0001 أسطر 442–452).
4. **Idempotency بطبقتين:** `unique(business_id, client_request_id)` (0001 سطر 176) + جدول `command_receipts` (0006 أسطر 19–28) مع إرجاع سلبي للمكرر في الدوال.
5. **فريد جزئي ذكي** لطلبات ربط معلقة واحدة لكل علاقة (0001 أسطر 153–155) و`unique nulls not distinct` في sync_checkpoints (0006 سطر 37).
6. **قيود CHECK شاملة:** أطوال نصوص، regex للعملة/الدولة/الهاتف/sha256، منطق scope في `statements` (0001 أسطر 359–363)، منع السداد الصفري المزدوج في `statement_items` (سطر 379)، وتناسق class/normal_balance في شجرة الحسابات (0010 أسطر 26–29).
7. **توازن اليومية مفروض قاعدياً:** constraint trigger مؤجل `trg_journal_entry_balanced` (0010 أسطر 219–221) يمنع commit أي قيد غير متوازن — ضمان على مستوى قاعدة البيانات لا التطبيق.
8. **فهارس ملائمة للاستعلامات المتوقعة:** مركّبة على (business_customer, occurred_at desc) و(business, occurred_at) و(customer, occurred_at) (0001 أسطر 412–414)، جزئية لـ due_date والإشعارات غير المقروءة وoutbox الجاهز (أسطر 415, 420–421)، وجاهزية automation_runs (0006 سطر 125).
9. **فصل PII:** أرقام الهواتف في `private.customer_contacts` مشفرة (AES-GCM) مع hash للبحث (0001 أسطر 80–91)، ومخطط `private` مسحوب الصلاحيات (سطر 9).
10. **فحص تطابق مرجعي يعوض حدود القيود الصرفة:** `validate_ledger_entry_insert` (0010 أسطر 321–344) يفرض تطابق tenant/customer/currency وقواعد العكس (reversal) التي يستحيل التعبير عنها بـ CHECK.

---

## 6. توصيات الإصلاح بترتيب الأولوية

1. **قبل أي نشر:** إما حذف/تعليق الترحيل 0012 بالكامل، أو إعادة كتابته من الصفر بعد حسم القرار المعماري لتعدد العملات (راجع 2.1). لا يجوز دمجه بحالته الحالية.
2. إن أُبقيت ميزة الأرصدة متعددة العملات: تعريف `business_permission`/`has_business_permission` أو استبدالها بـ `private.is_business_member`، تصحيح FK إلى `public.customers(id)`، توحيد الاتجاهات على debit/credit، تحويل الدالة الجديدة إلى مسار خاص `private.*` خلف غلاف عام موحّد مع كل فحوص التفويض والـ idempotency، وإضافة وظيفة مصالحة دورية للأرصدة.
3. حسم آلية إبطال قيود اليومية (قيد عكسي أو استثناء status في تريجر المنع).
4. إعادة توليد `full_schema.sql` بعد الاستقرار، وإضافة اختبار pgTAP يقارن المخطط الفعلي بالمرجع في CI.
5. تحويل `category`/`payment_method` إلى enums أو جداول مرجعية بقيود، وإزالة `attachment_url` لصالح منظومة `files`.
6. سد الثغرات الصغيرة: تريجر `updated_at` لـ `sync_checkpoints`، قيد regex لـ `statements.currency_code`، منع الفترات المفتوحة المتداخلة.

---

*انتهى التقرير — لم يُعدَّل أي ملف في المشروع.*
