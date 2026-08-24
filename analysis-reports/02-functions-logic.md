# تقرير تدقيق الدوال والمنطق البرمجي لقاعدة البيانات
## مدقق_الدوال_والمنطق (Functions & Triggers Auditor)

**نطاق التدقيق:** منطق قاعدة البيانات البرمجي كاملاً — الدوال (Commands)، المشغلات (Triggers)، تسلسل العمليات، الـ idempotency، حساب الأرصدة، منع التعديل، آلية العكس، سجل التدقيق، وحالات التسابق (Race Conditions).

**الملفات المدققة بشكل مباشر (نطاق المهمة):**
- `supabase/migrations/202607120002_functions_and_triggers.sql` (685 سطر)
- `supabase/migrations/202607120005_operations_audit.sql` (161 سطر)
- `supabase/migrations/202608140007_lint_and_link_command_fixes.sql` (116 سطر)
- `supabase/migrations/202608140008_member_invites_and_statement_commands.sql` (219 سطر)
- `supabase/migrations/202608140009_ledger_discount_enum.sql` (4 أسطر)
- `supabase/migrations/202608140011_accounting_command_receipts.sql` (12 سطر)

**ملفات داعمة قُرئت لاستكمال الصورة (لأنها تعيد تعريف نفس الدوال أو تضيف مشغلات على نفس الجداول):**
- `202607120001_core_schema.sql` — الجداول، القيود، مشغلات `prevent_update_delete`.
- `202607120003_rls_and_grants.sql` — الصلاحيات وسياسات RLS.
- `202608140006_platform_hardening_and_offline.sql` — إعادة تعريف أوامر القيود والنزاعات + `command_receipts`.
- `202608140010_double_entry_accounting.sql` — القيد المزدوج، إعادة تعريف `command_create_ledger_entry`، أمر الخصم.
- `202608180012_multi_currency_and_categories.sql` — تعدد العملات (وُجدت فيه أخطر الملاحظات).

> **ملاحظة منهجية:** الدالة `private.command_create_ledger_entry` أُعيد تعريفها 4 مرات (0002 ← 0006 ← 0007 ← 0010)، و`command_resolve_dispute` ثلاث مرات. التحليل أدناه يستند إلى **النسخة النهائية النافذة** (آخر تعريف بترتيب الـ migrations) مع الإشارة للنسخ الأقدم عند الحاجة.

---

## أولاً: الملاحظات الحرجة [حرج]

### 1. [حرج] مشغل تعدد العملات يعطّل كل عمليات الإدراج في دفتر القيود بالكامل
**الملف:** `202608180012_multi_currency_and_categories.sql`، الأسطر 51–111.

دالة المشغل `private.trig_update_customer_currency_balance()` مربوطة كـ `AFTER INSERT` على `public.ledger_entries` (السطر 109–111)، وفيها:

```sql
if new.direction = 'in' then ...  -- السطر 59
```

العمود `direction` نوعه `public.ledger_direction` وقيماه الوحيدتان `'debit'` و`'credit'` (معرّف في `202607120001_core_schema.sql:20`). مقارنة enum بنص `'in'` تؤدي إلى محاولة تحويل `'in'` إلى enum، فيُرفض برفض `22P02 invalid input value for enum ledger_direction` **عند كل تنفيذ**. وبما أن المشغل `AFTER INSERT`، فأي خطأ فيه يُجهض العملية كلها ويتراجع الإدراج.

**الأثر:** بعد تطبيق هذا الـ migration، **كل** محاولات إنشاء قيد (دين/سداد/خصم/عكس) تفشل — أي أن النظام المالي كله يتوقف عن الكتابة.

**مشكلة مركّبة ثانية في نفس المشغل:** الجدول `customer_currency_balances.customer_id` مُعرّف كمرجع إلى `public.profiles(id)` (السطر 17)، بينما المشغل يُدرج فيه `new.customer_id` الذي هو مرجع إلى `public.customers(id)` (السطر 82 — قيمة `customers.id` العشوائية وليست `auth.users.id`). هذا يضمن انتهاك مفتاح أجنبي شبه دائم حتى لو صُححت قيم الاتجاه.

### 2. [حرج] migration تعدد العملات يشير إلى دالة ونوع غير موجودين إطلاقاً
**الملف:** `202608180012_multi_currency_and_categories.sql`، السطر 41.

سياسة RLS تستدعي `public.has_business_permission(business_id, 'view_balances'::public.business_permission)`. بحث شامل في كل ملفات المشروع (migrations + `full_schema.sql`) أثبت أن **لا يوجد أي تعريف** لـ `has_business_permission` ولا للنوع `business_permission`. النتيجة: الـ migration يفشل عند `create policy`، ما يعني واحداً من أمرين:
- إما أن الـ migration لم يُطبَّق أصلاً (وعندها الأعمدة `category/payment_method/...` والجداول الجديدة غير موجودة رغم أن الكود قد يفترضها)،
- أو طُبِّق جزئياً يدوياً (وعندها قاعدة الإنتاج في حالة انحراف schema drift عن ملفات الـ migrations — وهذا بحد ذاته خطر إطلاق).

كما أن الملف يفتقد غلاف `begin;/commit;` الموجود في كل الملفات الأخرى.

### 3. [حرج] دالة `public.command_create_ledger_entry` الجديدة مسار كتابة مكسور وموازٍ بلا أي ضوابط
**الملف:** `202608180012_multi_currency_and_categories.sql`، الأسطر 114–209.

أنشئت دالة عامة جديدة `public.command_create_ledger_entry(...)` (توقيع مختلف كلياً عن `public.create_ledger_entry` القائم) وفيها تراكم أخطاء قاتلة:
- **السطر 157–163:** إسناد `'in'`/`'out'` إلى متغير `v_direction public.ledger_direction` → خطأ enum فوري قبل أي إدراج (الدالة ميتة عملياً).
- **السطر 157:** `p_entry_type in ('debt','fee')` — القيمة `'fee'` غير موجودة في `ledger_entry_type` إطلاقاً.
- **السطر 128 مقابل 203:** `p_source_device_id text` يُدرج في عمود `source_device_id uuid` → خطأ تحويل نوع عند تمرير أي قيمة.
- **لا يوجد أي فحص صلاحية** (`is_business_member` غائب كلياً — الأسطر 137–154 تفحص فقط وجود العميل ونشاط المحل). الدالة `security definer` وبواقع منح PostgreSQL الافتراضي `EXECUTE ... TO PUBLIC` للدوال الجديدة، فهي مكشوفة حتى لـ `anon`. (الذي يحول دون الكارثة فعلياً هو مشغل `validate_ledger_entry_insert` الذي يعيد فحص العضوية — لكن الاعتماد على مشغل كخط دفاع وحيد عن دالة عامة مكشوفة تصميم مرفوض).
- **لا فحص رصيد، لا حد ائتمان، لا idempotency، لا `command_receipts`** — بعكس المسار الرسمي.

---

## ثانياً: ملاحظات عالية الخطورة [عالي]

### 4. [عالي] تسابق حقيقي بين العكس (reversal) وبين إنشاء القيود: أرصدة سالبة وتجاوز للضوابط
**الملفات:** `202608140006_platform_hardening_and_offline.sql` الأسطر 267 (قفل `business_customers ... for update`) مقابل 314 (قفل `ledger_entries ... for update`).

أمر الإنشاء `command_create_ledger_entry` يُسلسل العمليات بقفل صف `business_customers`، لكن `command_reverse_ledger_entry` يقفل **صف القيد الأصلي** فقط ولا يلمس صف العميل. القفلان مختلفان، لذا يمكن تنفيذهما بالتوازي:

- رصيد العميل 100 (دين واحد 100).
- TX1: سداد 100 → يقفل العميل، فحص `100 <= 100` ينجح، يُدرج credit 100.
- TX2 (متزامن): عكس الدين 100 → يقفل القيد، لا يوجد عكس سابق، يُدرج credit 100.
- النتيجة بعد commit للاثنين: الرصيد = **−100** رغم أن كل فحص على حدة "نجح".

إضافةً إلى أن العكس نفسه بلا أي فحص رصيد: عكس دين سبق أن سُدد يدفع الرصيد للسالب دون أي اعتراض (ولا يرتبط ذلك بإعداد `allow_customer_credit_balance`).

### 5. [عالي] الـ idempotency معلَّن لثمانية أوامر ومُنفَّذ لثلاثة فقط
**الملفات:** `202608140011_accounting_command_receipts.sql` الأسطر 5–10 (وسّع `command_type` ليشمل `confirm_ledger_entry, open_dispute, add_dispute_message, resolve_dispute, apply_customer_discount, post_manual_journal`)، مقابل الواقع:
- `command_receipts` تُكتب فقط في `command_create_ledger_entry` (0010:372–373)، `command_reverse_ledger_entry` (0006:331–333)، `command_apply_customer_discount` (0010:398–399).
- `command_post_manual_journal` (0010:410–436) **لا يستقبل `client_request_id` أصلاً** ولا يكتب receipt → إعادة إرسال أمر قيد يدوي من طابور الأوفلاين تُنشئ قيداً محاسبياً مكرراً.
- أوامر النزاعات والتأكيد لا تكتب receipts (يعوّضها جزئياً قيود فريدة طبيعية مثل `entry_confirmations.entry_id unique`، لكن الالتزام التصميمي المعلن في 0011 غير مُنفَّذ).

### 6. [عالي] تناقض تصميمي: تعدد العملات مستحيل عبر المسار الرسمي
**الملفات:** `202608140010_double_entry_accounting.sql` الأسطر 329–330 مقابل `202608180012_multi_currency_and_categories.sql` كله.

مشغل `validate_ledger_entry_insert` يفرض `new.currency_code = businesses.currency_code` ويرفض أي قيد بعملة مختلفة. ومع ذلك يضيف migration 0012 معامل `p_currency_code` وجدول أرصدة لكل عملة `customer_currency_balances`. أي قيد بعملة غير عملة المحل سيرفضه المشغل، فلا يمكن لجدول الأرصدة متعدد العملات أن يحمل أكثر من عملة واحدة عملياً. ولو تجاوز أحد المشغل (بإدخال مباشر بصلاحية service) لانحرف `customer_currency_balances.current_balance` عن الرصيد المشتق من القيود (`business_customer_balances`) لأن الأول **مخزَّن ومُراكَّز بمشغل** والثاني **محسوب لحظياً** — مصدرا حقيقة متعارضان.

### 7. [عالي] كشف الحساب ليس لقطة متسقة (snapshot race) وبلا idempotency
**الملف:** `202608140008_member_invites_and_statement_commands.sql`، الأسطر 152–180.

`command_create_statement` يحسب الرصيد الافتتاحي في استعلام (152–154)، ثم مجاميع المدين/الدائن في استعلام ثانٍ (155–159)، ثم يُدرج البنود في استعلام ثالث (171–180) — **دون أي قفل** على `business_customers` أو غيره. قيد يُدرج (خاصة بتاريخ `occurred_at` رجعي — وهو مسموح بلا حدود) بين هذه الاستعلامات يجعل `total_debits/total_credits/closing_balance` غير مطابقة لمجموع `statement_items`، في كشف يُفترض أنه "موقّع ونهائي". كما لا يوجد `client_request_id` أو receipt → إعادة الطلب تُنشئ كشفاً مكرراً برمز تحقق جديد لنفس الفترة.

### 8. [عالي] دوال أُنشئت بعد migration الصلاحيات تحتفظ بمنح PUBLIC الافتراضي
**الملفات:** `202607120003_rls_and_grants.sql:33` (سحب شامل لكل الدوال الموجودة آنذاك) مقابل كل الـ migrations اللاحقة.

السحب في 0003 طال الدوال الموجودة لحظتها فقط. الدوال المُنشأة لاحقاً (0005–0012) تحصل افتراضياً على `EXECUTE TO PUBLIC` ولم تُسحب إلا بعض دوال `service_*`. أمثلة مكشوفة حالياً لـ anon/authenticated: `private.post_ledger_entry_journal(uuid)` (ينشئ قيوداً محاسبية لأي قيد دفتر لأي محل)، `private.initialize_business_chart(uuid)`، `private.expire_business_member_invites()`، `private.assert_posting_period_open(uuid,date)`، `private.trig_update_customer_currency_balance()`. معظمها محمي داخلياً أو ضارته محدودة، لكنه خرق صريح لحدود "التواصل عبر API المعرف فقط" ويوسّع سطح الهجوم بلا مبرر.

---

## ثالثاً: ملاحظات متوسطة [متوسط]

### 9. [متوسط] حارس "السداد يتجاوز الرصيد" معطَّل افتراضياً
**الملف:** `202608140010_double_entry_accounting.sql`، السطر 39 (`allow_customer_credit_balance boolean not null default true`) والسطر 367.

النسخة النهائية من `command_create_ledger_entry` لا ترفض السداد الزائد إلا إذا `allow_customer_credit_balance = false`، والافتراضي `true` → أي سداد بأي مبلغ يمر ويُنشئ رصيداً سالباً (دائن للعميل) بصمت. قد يكون قراراً تجارياً مقصوداً، لكنه يُبطل فحصاً كان إلزامياً في النسخ الأصلية (0002:395) ويجب توثيقه وإظهاره في الواجهة.

### 10. [متوسط] معالجة نزاع `partially_accepted` على قيد خصم تفشل دائماً
**الملفات:** `202608140006_platform_hardening_and_offline.sql:463–468` و`202608140010_double_entry_accounting.sql:356`.

عند القبول الجزئي يُستدعى `command_create_ledger_entry` بنوع القيد الأصلي `v_entry.entry_type`. إن كان الأصلي `discount` فالنسخة النهائية ترفضه برسالة "Use apply_customer_discount..." → تعذّر إغلاق أي نزاع جزئي على خصم إلا بـ `rejected` أو `accepted`.

### 11. [متوسط] العكس المباشر لقيد عليه نزاع نشط يقوّض مسار النزاع
**الملف:** `202608140006_platform_hardening_and_offline.sql`، الأسطر 302–336.

`command_reverse_ledger_entry` لا يفحص وجود نزاع نشط على القيد. يستطيع التاجر عكس القيد أثناء نزاع مفتوح، ثم تفشل `resolve_dispute(..., 'accepted')` لاحقاً بـ "Entry already reversed" (لأنها تستدعي العكس داخلياً، 0006:461) فيعلق النزاع بلا مسار إغلاق نظيف.

### 12. [متوسط] فجوات في تغطية سجل التدقيق (audit log)
**الملف:** `202607120005_operations_audit.sql`، الأسطر 37–43.

مشغل `audit_row_change` مربوط على 7 جداول فقط. **لا يوجد تدقيق** على: `business_member_invites` (قبول/رفض دعوات الفريق)، `statements` (إرفاق PDF/التجزئة)، `chart_of_accounts`، `accounting_periods` (إغلاق فترات — حدث محاسبي جوهري!)، `journal_entries`، `automation_rules`/`business_automation_settings`، وجدول `customer_currency_balances`. جداول القيود الثابتة مغطاة بجداول الأحداث (مقبول تصميمياً)، لكن إغلاق فترة محاسبية وتغيير دليل الحسابات بلا أثر تدقيقي ثغرة امتثال واضحة.

### 13. [متوسط] تسابق تأكيد/نزاع، وتأكيد قيود معكوسة
**الملفات:** `202608140006_platform_hardening_and_offline.sql` الأسطر 339–359 (confirm) و361–387 (open_dispute).

- `command_confirm_ledger_entry` يفحص غياب نزاع نشط، و`command_open_dispute` يأخذ قفلاً استشارياً على القيد — لكن التأكيد **لا يأخذ نفس القفل** → تأكيد + فتح نزاع متزامنان ينجحان معاً: قيد "مؤكد ومتنازع عليه" في آن.
- التأكيد لا يفحص `is_reversed` → يمكن تأكيد قيد عُكس مسبقاً، فيصبح `confirmation_status='confirmed'` لقيد ملغى.
- فتح النزاع لا يفحص التأكيد السابق ولا العكس السابق.

### 14. [متوسط] حالة `voided` للقيود المحاسبية ميتة وغير قابلة للوصول
**الملف:** `202608140010_double_entry_accounting.sql`، الأسطر 10 و121–124.

النوع `journal_entry_status` يعرف `'voided'`، لكن مشغل `trg_journal_entries_immutable` يمنع **أي** UPDATE على `journal_entries`، ولا توجد دالة void أصلاً → لا يمكن إبطال قيد محاسبي يدوي خاطئ إلا بقيد عكسي يدوي آخر (مقبول محاسبياً، لكن وجود قيمة enum ميتة مضلل). كذلك ميزان المراجعة `account_trial_balance` (الأسطر 465–477) لا يرشّح `status='posted'`، فلو وُجدت قيود voided مستقبلاً لتلوثت الأرصدة.

---

## رابعاً: ملاحظات منخفضة [منخفض]

15. **[منخفض]** `resolve_dispute` عند `rejected` يتجاهل `p_corrected_amount` بصمت ويعيد `null` رغم `returns uuid` — يجب رفض المعامل الزائد صراحة. (`202608140006:433–484`)
16. **[منخفض]** `occurred_at` يقبل تواريخ مستقبلية بلا سقف، و`due_date` يُحفظ فقط لنوع `debt`، ووصف العكس في النزاع `'تصحيح بسبب اعتراض: '||note` قد يتجاوز 500 حرف (قيد `ledger_entries.description`) فيفشل الإغلاق على ملاحظات طويلة. (`202608140006:461`)
17. **[منخفض]** الإشعارات تُرسل لـ `owner_user_id` فقط في أحداث الربط/التأكيد/النزاع، ولا تصل لبقية الإداريين/المحاسبين. (`202607120002:286–290, 467–468, 524–525`)
18. **[منخفض]** `gross_overdue_debits` في `business_customer_balances` (0002:663) يجمع الديون المتأخرة دون طرح السدادات — "إجمالي" حسب التسمية لكنه قد يضلل واجهة المتابعة.
19. **[منخفض]** سباقات محصورة بقيود فريدة (تأكيد مكرر، `client_request_id` مكرر تحت تزامن حقيقي) تطفو كأخطاء `23505` خام بدل رد idempotent نظيف. (`202608140006:351–357`)
20. **[منخفض]** `expire_link_requests` يعيد `link_status` إلى `'unlinked'` حتى لو كانت `'rejected'` قبل الطلب المنتهي — فقدان دلالة. (`202607120005:120–137`)
21. **[منخفض]** migration 0012 يضيف `category`/`payment_method` كنص حر بلا check constraints، والقيم الافتراضية `'goods'/'cash'` غير موثقة في enum. (`202608180012:5–10`)
22. **[منخفض]** تعدد إعادة التعريف (4 نسخ لدالة الإنشاء، 3 للإغلاق) + وجود `full_schema.sql` موازٍ يجعل الانحراف بين "ما هو مطبق" و"ما هو في الملفات" شبه حتمي — يُنصح باعتماد migrations مصدراً وحيداً وإعادة توليد `full_schema.sql` آلياً.
23. **[منخفض — ملاحظة تكامل عابرة للطبقات]** تطبيق Flutter يستدعي RPCs بأسماء غير موجودة في public: `command_add_dispute_message`, `command_resolve_dispute`, `command_invite_business_member`, `command_generate_statement` (`mobile/lib/features/merchant/data/merchant_repository.dart:349,367,422,452`) بينما المكشوف فعلياً `add_dispute_message`, `resolve_dispute`, `invite_business_member`, `create_statement`. (خارج نطاقي لكنه يمس سطح الدوال مباشرة).

---

## خامساً: نقاط إيجابية موثقة [إيجابي]

- **[إيجابي] نمط أوامر سليم:** دوال `private.command_*` بـ `security definer` + `set search_path=''` + أغلفة عامة رفيعة، مع إعادة فحص الصلاحية داخل مشغل `validate_ledger_entry_insert` كدفاع بالعمق. (0002:299–330)
- **[إيجابي] idempotency صحيح للقيود:** القيد الفريد `unique(business_id, client_request_id)` (0001:176) + فحص مسبق **بعد** قفل صف العميل (0006:267–276) يجعل إعادة تنفيذ نفس الأمر آمنة ومُسلسلة حتى تحت التزامن.
- **[إيجابي] ثبات مالي حقيقي:** مشغلات `prevent_update_delete` على كل جداول الوقائع المالية (0001:443–452) + قيد CHECK يربط نوع القيد باتجاهه (0010:314–319) + ضوابط العكس (تطابق المبلغ والعملة، عكس الاتجاه، منع عكس العكس، فرادة `reversal_of_entry_id`) (0010:335–341).
- **[إيجابي] outbox تعاملي احترافي:** إشعار + outbox في نفس المعاملة (0002:88–111)، سحب دفعات بـ `FOR UPDATE SKIP LOCKED` مع استرداد الأقفال العالقة (0005:46–77)، تراجع أسّي، وdead-letter بعد 8 محاولات (0006:216–239).
- **[إيجابي] طبقة قيد مزدوج رصينة:** مشغل توازن مؤجل `deferrable initially deferred` يفرض توازن القيد عند الـ commit (0010:204–221)، منع الترحيل في فترة مغلقة بتاريخ العملية الفعلي (0010:167–176, 254)، تعيين مدين/دائن صحيح لكل نوع (فتح/دين/سداد/خصم)، وقيود عكس تُعكس أسطر القيد الأصلي تلقائياً (0010:263–274).
- **[إيجابي] منع تكرار النزاعات بقفل استشاري** `pg_advisory_xact_lock` (0006:372) وقفل `dispute_state ... for update` في الرسائل والإغلاق (0006:403, 450).
- **[إيجابي]** عروض القراءة بـ `security_invoker=true` وRLS افتراضي مانع — القراءة لا يتجاوز الصلاحيات. (0002:653–683)

---

## سادساً: خلاصة التقييم

البنية الأساسية (0001–0011) **متينة ومدروسة**: نمط أوامر، idempotency، ثبات مالي، قيد مزدوج متوازن، outbox تعاملي. المخاطر الحقيقية تتركز في:
1. **migration 0012 (تعدد العملات) كتلة مكسورة بالكامل** — مشغل يوقف كل الكتابة المالية، مراجع ودوال غير موجودة، ودالة عامة موازية بلا ضوابط. **لا يمكن الإطلاق قبل إصلاحه أو حذفه.**
2. **تسابق العكس مقابل الإنشاء** (ملاحظة 4) — يحتاج قفل صف `business_customers` في `command_reverse_ledger_entry` أيضاً.
3. **لقطة كشف الحساب غير المتسقة** (ملاحظة 7) — تحتاج قفلاً أو قراءة بمستوى عزل أعلى.

**إحصاء الملاحظات:** حرج 3 · عالي 5 · متوسط 6 · منخفض 9 · إيجابي 7.
