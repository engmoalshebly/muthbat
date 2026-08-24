# تقرير تدقيق تعدد العملات (Multi-Currency Audit)

**المدقق:** مدقق_تعدد_العملات
**النطاق:** `debt-ledger-supabase/supabase/migrations/202608180012_multi_currency_and_categories.sql` + تتبّع أثر `currency` في كامل الباكند (`debt-ledger-supabase/supabase`) وتطبيق الموبايل (`mobile/lib`)
**المنهجية:** قراءة فعلية لكل ملفات الـ migrations الـ 12، والدوال ذات الصلة، وملفات Dart الـ 18 التي تحتوي مراجع عملة، مع مقارنة التواقيع بين واجهة الموبايل ودوال RPC.

---

## 1. ملخص تنفيذي

ميزة تعدد العملات في هذا المشروع **غير قابلة للتشغيل إطلاقاً بحالتها الحالية**. الـ migration المسؤول عنها (`202608180012`) **لن ينجح تطبيقه أصلاً** لأنه يشير إلى دالة ونوع بيانات غير موجودين في قاعدة البيانات. وحتى لو أُصلح ذلك، فإن التريجر والدالة الجديدة فيه يستخدمان قيماً (`'in'`/`'out'`/`'fee'`) **غير موجودة في الـ enums الفعلية** (`debit`/`credit`، و`opening_balance/debt/payment/discount/reversal`)، مما سيعطّل **كل** عمليات إدخال القيود المالية في النظام. وفوق ذلك، الموبايل يستدعي دوال RPC بتواقيع لا تطابق أي دالة منشورة، وتريجر التحقق الأصلي يمنع أي عملة مخالفة لعملة المحل — أي أن "تعدد العملات" متناقض معماريًا مع بقية النظام. لا يوجد أي تحويل بين العملات (لا أسعار صرف)، والتصميم يفترض فصلاً كاملاً بين العملات لكن الشاشات والـ views والمحاسبة القيد المزدوج تجمع المبالغ بلا تمييز عملة في مواضع عدة.

**الحكم: الميزة غير جاهزة للإطلاق — حرجة بامتياز.**

---

## 2. النتائج التفصيلية

### 2.1 ملاحظات حرجة [حرج]

---

#### [حرج] 1 — الـ migration نفسه غير قابل للتطبيق: سياسة RLS تشير إلى دالة ونوع غير موجودين

**الملف:** `debt-ledger-supabase/supabase/migrations/202608180012_multi_currency_and_categories.sql:38-43`

```sql
create policy "customer_currency_balances_select_member"
on public.customer_currency_balances for select
using (
  public.has_business_permission(business_id, 'view_balances'::public.business_permission)
  ...
```

بحث شامل في كامل مجلد `debt-ledger-supabase` (كل الـ migrations + `full_schema.sql` + الدوال) أثبت أن:
- الدالة `public.has_business_permission` **غير معرّفة في أي مكان** (الدالة الموجودة فعلياً هي `private.is_business_member` — `202607120002_functions_and_triggers.sql:17`).
- النوع `public.business_permission` **غير معرّف في أي مكان** (لا يوجد `create type ... business_permission`).

**الأثر:** `create policy` يتحقق من صحة التعبير عند الإنشاء، لذا سيفشل الـ migration كاملاً ويتراجع (rollback). النتيجة: جدول `customer_currency_balances`، والتريجر، والدالة الجديدة، وحتى أعمدة `category/payment_method/reference_number/bank_or_agent_name/attachment_url` (الأسطر 5-10) **لن توجد في قاعدة البيانات** رغم أن الموبايل يفترض وجودها. هذا يفسّر أيضاً لماذا `full_schema.sql` لا يحتوي أي أثر لهذا الـ migration (انظر الملاحظة 15).

---

#### [حرج] 2 — تريجر أرصدة العملات يستخدم قيمة enum غير موجودة: سيعطّل كل إدخالات القيود

**الملف:** `202608180012_multi_currency_and_categories.sql:58-65`

```sql
if new.direction = 'in' then
  v_direction_sign := 1;
```

النوع الفعلي: `create type public.ledger_direction as enum ('debit','credit')` (`202607120001_core_schema.sql:20`). مقارنة عمود enum بنص `'in'` تُجبر PostgreSQL على تحويل `'in'` إلى `ledger_direction` → خطأ `invalid input value for enum ledger_direction: "in"` (22P02) **عند كل INSERT** في `ledger_entries`.

**الأثر:** بما أن التريجر `trg_ledger_entry_currency_balance` مربوط `after insert on public.ledger_entries` (الأسطر 108-111)، فإن نجاح تطبيق هذا الـ migration يعني **تعطيل مسار إنشاء القيود بالكامل** — بما فيه المسار القديم السليم (`create_ledger_entry`)، لأن التريجر يعمل على كل صف. حتى لو لم يحدث خطأ التحويل، فالمنطق معكوس: `direction='in'` لن يتحقق أبداً فيُعامل كل قيد كأنه سالب.

---

#### [حرج] 3 — الدالة الجديدة `command_create_ledger_entry` فاشلة منطقياً: `'in'/'out'/'fee'` غير موجودة في الـ enums

**الملف:** `202608180012_multi_currency_and_categories.sql:156-163`

```sql
if p_entry_type in ('debt', 'fee') then
  v_direction := 'in';
elsif p_entry_type in ('payment', 'discount') then
  v_direction := 'out';
```

- `v_direction` معرّف `public.ledger_direction` (سطر 132) وقيمه الوحيدة `debit`/`credit` → تعيين `'in'` أو `'out'` يرمي خطأ enum فوراً.
- `'fee'` ليس ضمن `ledger_entry_type` الذي قيمه `('opening_balance','debt','payment','discount','reversal')` (`202607120001_core_schema.sql:19` + `202608140009_ledger_discount_enum.sql:3`) → تمرير `'fee'` يفشل قبل الوصول للجسم.
- لاحظ أن قيد `ledger_entries_check` (`202608140010_double_entry_accounting.sql:315-319`) يفرض `debt→debit` و`payment/discount→credit`، أي حتى إصلاح القيم يتطلب `'debit'/'credit'` لا `'in'/'out'`.

**الأثر:** الدالة التي يفترض أنها مدخل تعدد العملات **لا يمكن أن تنجح أبداً**.

---

#### [حرج] 4 — عدم تطابق تواقيع RPC بين الموبايل والسيرفر: مزامنة القيود ستفشل دائماً

**الموبايل:** `mobile/lib/core/sync/sync_engine.dart:122-125` يستدعي `client.rpc('create_ledger_entry', params: payload)` حيث الـ payload المبني في `mobile/lib/features/merchant/data/merchant_repository.dart:129-143` يحتوي **12 معاملاً مسماة**: `p_business_customer_id, p_entry_type, p_amount, p_currency_code, p_category, p_payment_method, p_reference_number, p_bank_or_agent_name, p_attachment_path, p_description, p_due_date, p_occurred_at, p_client_request_id`.

**السيرفر:** الدالة العامة الوحيدة باسم `create_ledger_entry` توقيعها **9 معاملات فقط بلا عملة/تصنيف** (`202607120002_functions_and_triggers.sql:413-425`، ومُنحت EXECUTE في `202607120003_rls_and_grants.sql:60`). الدالة ذات الـ 14 معاملاً التي تقبل العملة اسمها المختلف تماماً `public.command_create_ledger_entry` (`202608180012:114`) — والموبايل لا يستدعيها، وهي نفسها معطوبة (الملاحظة 3).

نفس المشكلة في الخصم: الموبايل يرسل `p_currency_code` ضمن payload الخصم (`merchant_repository.dart:190-196`) بينما `public.apply_customer_discount` توقيعها `(uuid,numeric,text,timestamptz,uuid)` بلا عملة (`202608140010:378-379`، والمنحة في `202608140010:505`).

**الأثر:** PostgREST يطابق الدوال بالمعاملات المسماة بدقة؛ أي معامل زائد ينتج `PGRST202 Could not find the function`. كل عمليات `create_ledger_entry` و`apply_customer_discount` في طابور الأوفلاين **ستفشل عند أول مزامنة** وتبقى معلقة إلى الأبد (مع بقاء الأرصدة المحلية "التفاؤلية" غير المطابقة للسيرفر).

---

#### [حرج] 5 — تناقض معماري جوهري: تريجر التحقق يمنع تعدد العملات فعلياً

**الملف:** `202608140010_double_entry_accounting.sql:329-330` (وأصله `202607120002:309-310`)

```sql
select currency_code into v_currency from public.businesses where id=new.business_id and status='active';
if v_currency is null or v_currency<>new.currency_code then raise exception 'Currency or business status mismatch'; end if;
```

تريجر `validate_ledger_entry_insert` (before insert) **يفرض أن عملة كل قيد = عملة المحل**، ولم يعدّله أو يعطّله الـ migration 012. أي أنه حتى بعد إصلاح كل الأخطاء أعلاه، أي محاولة لقيد بعملة غير عملة المحل (مثلاً SAR في محل YER) **ستُرفض**. كما أن كل دوال الإنشاء الأصلية (`202608140010:362-371` و`394-397`) تسحب عملة المحل قسراً وتتجاهل أي عملة يمررها العميل.

**الأثر:** النظام له شخصيتان متناقضتان: البنية التحتية الأصلية "عملة واحدة لكل محل بصرامة"، والـ migration 012 "عملة حرة لكل قيد". لا يمكن إطلاق الميزة قبل حسم هذا التناقض (إما تعدد عملات حقيقي مع تحديث التريجر والمحاسبة والكشوفات، أو إزالة واجهة اختيار العملة من الموبايل).

---

### 2.2 ملاحظات عالية [عالي]

---

#### [عالي] 6 — الـ views ودوال الكشوفات تجمع مبالغ بعملات مختلفة بلا تجميع حسب العملة

- `public.business_customer_balances` (`202607120002_functions_and_triggers.sql:653-670`): `sum(case when le.direction='debit' then amount else -amount end)` على كل قيود العميل **بلا `group by currency_code` ولا فلتر**، مع إظهار `b.currency_code` (عملة المحل) كأنها عملة المجموع.
- `public.business_customer_account_positions` (`202608140010:479-490`): نفس النمط — `receivable_signed_balance` مجموع مختلط محتمل.
- `public.customer_account_overview` (`202607120002:658-670`): نفس الشيء.
- `command_generate_statement` (`202608140008_member_invites_and_statement_commands.sql:152-164`): يحسب `opening/debits/credits/closing` بجمع كل القيود **بلا `and currency_code = v_currency`** ثم يخزن الناتج موسوماً بعملة المحل (سطر 164). لاحظ التناقض الداخلي: الفرع الموحّد للعميل (consolidated) يرفض تعدد العملات صراحة (الأسطر 148-150: `'Consolidated statements require a single currency'`) بينما فرع كشف عميل-محل لا يفلتر ولا يرفض.

**الأثر:** لو وُجدت قيود بعملتين لعميل واحد (وهو ما تَعِد به واجهة الموبايل)، فكل الأرصدة والكشوفات الموقعة ستكون **مجاميع بلا معنى** (500 ر.ي + 100 $ = 600 "ر.ي"). الكشوفات موقعة/موثقة قانونياً، فالخطأ هنا ذو أثر تجاري وقانوني.

---

#### [عالي] 7 — المحاسبة القيد المزدوج بلا عملة: journal_entry_lines لا تخزن currency_code

**الملف:** `202608140010_double_entry_accounting.sql:76-88` — جدول `journal_entry_lines` فيه `debit_amount/credit_amount numeric(20,4)` فقط، ولا عمود عملة في الخطوط ولا في `journal_entries` (الأسطر 60-74). دالة الترحيل `post_ledger_entry_journal` (الأسطر 239-297) تنسخ `v_entry.amount` فقط وتتجاهل `v_entry.currency_code`.

**الأثر:** دفتر الأستاذ وميزان المراجعة سيجمعان قيوداً بعملات مختلفة في حساب واحد بلا أي تمييز أو تحويل — خرق محاسبي جوهري لمبدأ وحدة القياس، ويجعل التقارير المحاسبية غير صالحة في وجود أكثر من عملة.

---

#### [عالي] 8 — الموبايل: أرصدة العملات المحلية لا تُزامَن من السيرفر إطلاقاً، والتحديث التفاؤلي ناقص

- `sync_engine.dart:187-193` (السحب من السيرفر) يقرأ الرصيد من الـ view أحادي العملة `business_customer_balances` فقط ويحدّث `current_balance` المسطّح؛ **لا يوجد أي سحب لجدول `customer_currency_balances`** رغم وجود الجدول المحلي `local_customer_currency_balances` (`app_database.dart:42-55`).
- التحديث التفاؤلي المحلي `saveLedgerEntryOptimistic` (`app_database.dart:405-411`) يحدّث أرصدة العملات فقط لأنواع `debt/fee/payment/discount` و**يتجاهل `reversal` و`opening_balance`**، بينما قيود العكس تُنشأ فعلاً من الموبايل (`merchant_repository.dart:223-252` بـ `entryType: 'reversal'`).
- كما أن الرصيد المسطّح `current_balance` في `local_business_customers` يُحدَّث محلياً بجمع كل العملات معاً (`app_database.dart:438-459`) — خلط عملات في رقم واحد.

**الأثر:** أرصدة العملات المعروضة في الموبايل تنحرف تدريجياً عن الحقيقة: قيود الأجهزة الأخرى والعكس والأرصدة الافتتاحية لا تنعكس، ولا توجد أي دورة تصحيح (reconciliation) من السيرفر.

---

#### [عالي] 9 — إجماليات لوحة التاجر تجمع عملات مختلفة في رقم واحد معروض برمز عملة واحد

`merchant_controller.dart:122-124` يجمع `c.amountCustomerOwes` و`c.amountBusinessOwesCustomer` (حقول مسطحة مختلطة العملات — انظر الملاحظة 8) في `totalReceivables/totalPayables`، ثم يعرضها `merchant_home_screen.dart:447-456` بجانب `state.currency` (رمز واحد، `'ر.ي'` افتراضياً — `merchant_controller.dart:26,143`). بنية `currencyBreakdown` الصحيحة موجودة (`merchant_controller.dart:17,126-137`) لكن البطاقة الرئيسية لا تستخدمها.

**الأثر:** الرقم الأبرز في التطبيق (إجمالي "لك" و"عليك") قد يكون مجموع ريال يمني + ريال سعودي + دولار معروضاً كأنه عملة واحدة — تضليل مالي مباشر للتاجر.

---

#### [عالي] 10 — الدالة الجديدة `command_create_ledger_entry` (012) بلا فحص صلاحيات ولا فحوص رصيد ولا idempotency

مقارنة بالدالة الأصلية (`202608140010:354-375`)، الدالة الجديدة (`202608180012:114-208`):
- **لا تستدعي `is_business_member`** — أي مستخدم موثّق يعرف `business_customer_id` يمكنه إنشاء قيود (تريجر `validate_ledger_entry_insert` هو خط الدفاع الوحيد، وهو حالياً ما يمنعها، لكن الاعتماد على تريجر لتحقق الصلاحيات هشّ وغير مقصود تصميمياً).
- لا فحص `payment exceeds current balance` ولا `credit_limit` (موجودان في الأصلية، `202608140010:365-368`) — والأصح أن يكونا **لكل عملة** لا على المجموع المختلط.
- لا تسجيل في `command_receipts` (idempotency) رغم قبولها `p_client_request_id` — إعادة إرسال نفس الطلب تُنشئ قيداً مكرراً (الأصلية تفحص في `202608140010:360-361`).
- لا منحة EXECUTE صريحة لها في أي migration (المنح موجودة للدوال الأخرى في `202607120003:56-83` و`202608140010:505-511`).

---

### 2.3 ملاحظات متوسطة [متوسط]

---

#### [متوسط] 11 — رموز عملة ثابتة `'ر.ي'` في شاشات تعرض مبالغ قد تكون بعملات أخرى

- `mobile/lib/features/customer/presentation/screens/customer_home_screen.dart:259` — المبلغ المستحق على العميل معروض دائماً `ر.ي`.
- `mobile/lib/features/merchant/presentation/screens/disputes_list_screen.dart:299` و`dispute_detail_screen.dart:225` و`widgets/resolve_dispute_sheet.dart:126` — مبلغ النزاع `ر.ي` ثابت رغم أن النزاع مربوط بقيد له `currency_code` (الموديل يجلبه فعلاً في `merchant_repository.dart:298` لكنه لا يُستخدم في العرض).
- `mobile/lib/features/merchant/presentation/screens/statement_preview_screen.dart:246,279` — كشف الحساب يعرض `ر.ي` ثابت رغم وجود `statement.currencyCode` في الموديل (`statement_model.dart:9,49`).
- `create_ledger_entry_sheet.dart:319` — fallback الرصيد يعرض `ر.ي` عند غياب `currencyBalances` حتى لو كانت عملة المحل SAR.

---

#### [متوسط] 12 — لا يوجد أي تحويل بين العملات ولا أسعار صرف، وعملة المحل ثابتة `'YER'` برمجياً

- لا يوجد جدول أسعار صرف ولا دالة تحويل في كامل الباكند (بحث `exchange|rate|convert` بلا نتائج ذات صلة). الفصل بين العملات كامل، وهو قرار تصميمي مقبول، لكنه غير موثّق للمستخدم ولا تظهر بسببه أي إجماليات موحدة صحيحة (الملاحظة 9).
- إنشاء المحل من الموبايل يثبّت العملة `'YER'` قسراً في ثلاث نقاط: `auth_controller.dart:164,262,453` و`merchant_controller.dart:98` — لا يمكن للتاجر اختيار عملة محله من التطبيق، بينما واجهة القيد تتيح YER/SAR/USD (`create_ledger_entry_sheet.dart:43-47`). عميل محل SAR الذي يُنشأ من التطبيق سيُسجَّل YER.

---

#### [متوسط] 13 — التصنيفات (categories) وطرق السداد نصوص حرة بلا قيود

`202608180012:5-10` يضيف `category text default 'goods'` و`payment_method text default 'cash'` **بلا `check` constraint ولا enum**. الموبايل يفترض مجموعات مغلقة (`goods/cash/service/transfer/other` و`cash/bank_transfer/cheque/offset` — `ledger_entry_model.dart:10-11`) لكنه يرسل أيضاً قيم خارجها (`category: 'discount'`, `paymentMethod: 'discount'` في `merchant_repository.dart:178-179`). لا يوجد تحقق في السيرفر ولا توحيد، ما يفتح الباب لتشتت التقارير حسب التصنيف.

---

#### [متوسط] 14 — إشعارات الأتمتة تستخدم عملة المحل بدل عملة القيد

`process-automation-rules/index.ts:207,235` يرسل `currency: business.currency_code` في حمولة إشعار واتساب رغم أن القيد `entry` له `currency_code` خاص. في بيئة متعددة العملات سيصل العميل إشعار بمبلغ SAR موسوماً YER.

---

### 2.4 ملاحظات منخفضة [منخفض]

---

#### [منخفض] 15 — `full_schema.sql` قديم ولا يعكس الـ migration 012

لا يحتوي `customer_currency_balances` ولا أعمدة التصنيف ولا الدالة الجديدة (بحث `currency` فيه يُظهر فقط تعريفات ما قبل 012). أي بيئة تُبنى من `full_schema.sql` ستفتقد الميزة كلياً — أو أي مبرمج يعتمد عليه كمرجع سيحصل على صورة غير مكتملة للمخطط.

#### [منخفض] 16 — ترقية قاعدة SQLite المحلية لا تضيف عمود `currency_code` للتثبيتات القديمة

`_ensureLatestSchema` (`app_database.dart:57-72`) يضيف `category/payment_method/reference_number/bank_or_agent_name/attachment_path` لكن **لا يضيف `currency_code`** إلى `local_ledger_entries`. إن كانت قاعدة الإصدار 1 تفتقده، فكل الاستعلامات المفلترة بالعملة (`app_database.dart:352-354`) ستفشل على الأجهزة المحدَّثة. (يحتاج تأكيداً من مخطط v1 الفعلي، لكن غيابه من قائمة الـ ALTER مؤشر خطر.)

#### [منخفض] 17 — دقة التخزين والتقريب: numeric(20,4) مقابل REAL/double

السيرفر يخزن `numeric(20,4)` (دقة عشرية مضمونة)، بينما الموبايل يستخدم `double` في Dart و`REAL` في SQLite (`app_database.dart:47-49,138`) — فاصلة عائمة ثنائية تُنتج فروق تقريب تراكمية في الأرصدة المحلية (خاصة مع مبالغ يمنية كبيرة بالآلاف والملايين). كما لا يوجد أي اعتبار للوحدات الصغرى لكل عملة (minor units: الكويتية 3 خانات، اليابانية 0) — التنسيق ثابت بخانتين (`generate-statement/index.ts:46-49`).

---

### 2.5 نقاط إيجابية [إيجابي]

1. **[إيجابي]** تحقق صارم من صيغة رمز العملة ISO عبر `check (currency_code ~ '^[A-Z]{3}$')` في `businesses` و`ledger_entries` و`customer_currency_balances` (`202607120001:99,166`؛ `202608180012:18`)، مع تطبيع `upper(trim(...))` قبل التخزين (`202608180012:147-150`).
2. **[إيجابي]** فصل الأرصدة حسب العملة بقيد فريد `unique(business_customer_id, currency_code)` وتحديث ذرّي عبر `insert ... on conflict do update` (`202608180012:25,91-98`) — التصميم نفسه سليم لو أُصلحت الأخطاء.
3. **[إيجابي]** حارس الكشف الموحّد: رفض الكشوفات المجمعة متعددة العملات صراحة (`202608140008:148-150`) بدل إنتاج كشف مختلط صامت.
4. **[إيجابي]** العكس (reversal) يفرض تطابق المبلغ **والعملة** مع القيد الأصلي (`202608140010:339`) — يمنع عكس قيد بعملة مختلفة.
5. **[إيجابي]** `currency_code` في `ledger_entries` كان `not null` منذ أول migration، فلا توجد بيانات قديمة بلا عملة؛ وأعمدة التصنيف الجديدة لها defaults تملأ الصفوف القديمة تلقائياً (`202608180012:6-7`).
6. **[إيجابي]** واجهة الموبايل متقدمة تصميمياً: محدد عملات، فلترة قيود حسب العملة (`customer_ledger_screen.dart:31,363-369`)، عرض أرصدة مجزأة حسب العملة (`merchant_home_screen.dart:1274-1340`)، وبنية `currencyBreakdown` في الحالة.
7. **[إيجابي]** كشف الحساب يخزن `currency_code` ويعرضه في PDF (`generate-statement/index.ts:161,205`) ويُرجعه في التحقق العام (`verify-statement/index.ts:19`).

---

## 3. كيف تُخزن العملة وتُحسب الأرصدة (خريطة معمارية)

| الطبقة | التخزين | الحساب | الحالة |
|---|---|---|---|
| المحل | `businesses.currency_code` (إلزامي، ISO) | — | سليم، لكن الموبايل يثبّته YER |
| القيد | `ledger_entries.currency_code` (إلزامي) | تريجر يفرض = عملة المحل | يمنع تعدد العملات فعلياً |
| أرصدة متعددة العملات | `customer_currency_balances` (لكل عميل×عملة) | تريجر 012 | **معطوب كلياً (enum)** |
| الأرصدة المسطحة | views `business_customer_balances` وغيرها | sum بلا تجميع عملة | تخلط العملات عند وجودها |
| المحاسبة | `journal_entry_lines` | بلا عمود عملة | فاقدة للعملة |
| الكشوفات | `statements.currency_code` | مجاميع بلا فلتر عملة (فرع المحل) / رفض التعدد (فرع التجميع) | متناقضة |
| الموبايل | `local_customer_currency_balances` + حقول مسطحة | تفاؤلي محلي فقط، بلا تصحيح من السيرفر | ينحرف عن الحقيقة |

**الإجابة عن أسئلة المهمة المباشرة:**
- **تحويل بين العملات؟** لا يوجد إطلاقاً — فصل كامل نظرياً، لكن بلا حواجز تحسب المجاميع بفصل فعلي.
- **هل يمكن جمع عملات مختلفة بالخطأ؟** نعم: في الـ views الثلاثة، وفي `command_generate_statement`، وفي `totalReceivables` بالموبايل، وفي `current_balance` المسطّح محلياً.
- **البيانات القديمة بعد إضافة العملة؟** العملة موجودة إلزامياً منذ البداية فلا مشكلة؛ التصنيفات تُملأ بـ defaults.
- **العملة الافتراضية؟** `'YER'` مثبتة في 4 مواضع بالموبايل وكـ default في دالة 012 (سطر 118)، مع سقوط صامت إلى YER عند رمز غير صالح (الأسطر 148-150) بدل رفض الطلب — ما قد يُسجّل قيداً بعملة غير التي قصدها المستخدم.

---

## 4. التوصيات (بترتيب الأولوية)

1. **إصلاح الـ migration 012 أو إعادة كتابته:** تعريف/تصحيح `has_business_permission` و`business_permission` (أو استخدام `private.is_business_member` الموجود)، وتصحيح `'in'/'out'` → `'debit'/'credit'`، وإزالة `'fee'` أو إضافته للـ enum بوعي.
2. **حسم التناقض المعماري:** إما تعدد عملات حقيقي (تحديث `validate_ledger_entry_insert`، وإضافة العملة للـ journal lines، وتجميع كل الـ views والكشوفات حسب `currency_code`) أو عملة واحدة (إزالة محدد العملات من الموبايل).
3. **توحيد واجهة RPC:** نشر دالة عامة واحدة `create_ledger_entry` بالتوقيع الكامل الذي يرسله الموبايل (مع منحة EXECUTE)، وإضافة `p_currency_code` لـ `apply_customer_discount` أو إزالته من payload الموبايل.
4. **مزامنة أرصدة العملات:** سحب `customer_currency_balances` في `_pullRemoteUpdates`، ومعالجة `reversal/opening_balance` في التحديث التفاؤلي، وعدم جمع العملات في `current_balance` المسطّح.
5. **عرض مجزأ:** استخدام `currencyBreakdown` في البطاقة الرئيسية بدل الإجمالي المختلط، واستبدال كل `'ر.ي'` الثابتة برمز عملة السجل الفعلي.
6. **اختبارات:** لا يوجد أي اختبار قاعدة بيانات يغطي العملات (`supabase/tests/database` خالٍ من `currency`) — إضافة اختبارات pgTAP للتريجر والدالة والكشوفات متعددة العملات قبل الإطلاق.

---

*انتهى التقرير — مدقق_تعدد_العملات*
