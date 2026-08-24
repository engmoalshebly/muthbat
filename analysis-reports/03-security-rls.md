# تقرير تدقيق الأمان و RLS — مشروع دفتر الديون (Debt Ledger)

**المدقق:** مدقق_الأمان_RLS (Security & RLS Auditor)
**النطاق:** باكند Supabase في `debt-ledger-supabase` — المايقريشن (12 ملفاً)، Edge Functions التسعة + `_shared`، `config.toml`، `.env.example`، `docs/rls-matrix.md`، مع إشارات لتطبيق Flutter عند تقاطع الأسرار/التوثيق.
**المنهجية:** قراءة فعلية لكل ملف، مطابقة قائمة الجداول (`create table`) مقابل تفعيل RLS، تتبّع GRANT/REVOKE، وفحص دوال `security definer` وسياسات Storage وRealtime.

---

## 1. ملخص التغطية (نظرة عامة)

- عدد الجداول العامة (`public.*`) عبر كل المايقريشن: **31 جدولاً** — **كلها** عليها `enable row level security` (تحققت بالمطابقة الكاملة بين قوائم `create table` و`enable row level security`).
- الجداول الحساسة في `private.*` (جهات الاتصال المشفرة، outbox، audit_logs، rate limits…): معزولة بـ `revoke all on schema private` (`202607120001_core_schema.sql:9`).
- النموذج العام **default-deny** سليم البنية: سحب شامل ثم منح انتقائية (`202607120003_rls_and_grants.sql:30-53`).
- لكن توجد **ثغرات حرجة** في المايقريشن الأخير `202608180012` وفي طبقة OTP/واتساب تُبطل فعلياً جزءاً من هذا الانضباط — مفصلة أدناه.

---

## 2. الملاحظات الحرجة [حرج]

### ح-1: مفتاح OpenWA API مكشوف وثابت في الكود المصدري (سيبحر مع المنتج)
- `supabase/functions/send-whatsapp-otp/index.ts:4-5`: قيم افتراضية حقيقية الشكل:
  - `OPENWA_SESSION_ID = "[REDACTED]"`
  - `OPENWA_API_KEY = "[REDACTED]"`
- **نفس المفتاح مكرر حرفياً في تطبيق الموبايل**: `mobile/lib/core/services/whatsapp_otp_service.dart:28-29` كثوابت `const` — أي شخص يفكك الـ APK/IPA يستخرجه ويرسل رسائل واتساب اعتباطية من جلسة التاجر.
- إضافة إلى عناوين شبكة داخلية ثابتة في `whatsapp_otp_service.dart:32-36` (`http://192.168.0.134:2785/api`).
- **الإجراء:** إبطال المفتاح فوراً، نقله إلى أسرار Edge Function فقط، ومنع اتصال العميل ببوابة واتساب مباشرة.

### ح-2: دالة عامة `public.command_create_ledger_entry` بلا أي فحص تفويض — كتابة عابرة للمستأجرين
- `202608180012_multi_currency_and_categories.sql:114-209`: دالة في schema العام `public`، `security definer`، **بلا** `set search_path`، **وبلا أي استدعاء لـ `is_business_member`** — تكتفي بفحص أن المحل `active` وأن المبلغ موجب (سطور 142-154).
- لم يصدر عليها أي `revoke`؛ والافتراضي في PostgreSQL منح `EXECUTE` لدور `PUBLIC` على الدوال الجديدة (سحب 0003:32 لا يشمل دوال أُنشئت بعده). النتيجة: **أي مستخدم مصادق — بل وحتى دور anon — يستطيع إدراج قيود دين/سداد في أي `business_customer_id` لأي محل**، متجاوزاً حد الائتمان وفحوص الأدوار وإيصالات idempotency الموجودة في النسخة الصحيحة `private.command_create_ledger_entry` (`202608140010_double_entry_accounting.sql:346-376` والتي تفحص الأدوار في سطر 359).
- للمقارنة: المسار السليم يمر عبر `public.create_ledger_entry` → `private.command_*` مع فحص أدوار (`owner/admin/accountant/cashier`).

### ح-3: سياسة RLS تشير إلى دالة ونوع غير موجودين — المايقريشن 0012 غير قابل للتطبيق
- `202608180012_multi_currency_and_categories.sql:38-43`: السياسة `customer_currency_balances_select_member` تستدعي `public.has_business_permission(...)` وتقوم بتحويل النوع `'view_balances'::public.business_permission`.
- بحث شامل في كامل المشروع: **لا وجود** لتعريف الدالة أو النوع في أي ملف. `create policy` سيفشل عند التطبيق → **المايقريشن بأكمله (تعدد العملات + التصنيفات) غير قابل للنشر**، وكل ما بعده معطّل.

### ح-4: تضارب مفاتيح أجنبية وقيم enum في 0012 — تريجر يعطّل كل إدراج قيد
- `customer_currency_balances.customer_id references public.profiles(id)` (0012:17) بينما التريجر `private.trig_update_customer_currency_balance` ينسخ `new.customer_id` من `ledger_entries` الذي يشير إلى `public.customers(id)` (`202607120001_core_schema.sql:162`) → **انتهاك FK عند كل إدراج قيد**.
- التريجر والدالة يستخدمان `direction = 'in'/'out'` (0012:59-64, 158-162) بينما `public.ledger_direction as enum ('debit','credit')` (0001:20) → انتهاك enum.
- `entry_type = 'fee'` (0012:157) غير موجود في `ledger_entry_type` (0001:19 + 0009:3 يضيف `discount` فقط).
- الوصف الافتراضي `p_description text default ''` (0012:123) يخالف `check (char_length(trim(description)) between 2 and 500)` (0001:167).
- التريجر مربوط `after insert on public.ledger_entries` (0012:108-111) → لو طُبق المايقريشن لعطّل **كل** عمليات إنشاء القيود في النظام.

### ح-5: التحقق من رمز OTP يتم بالكامل على جهاز العميل — لا قيمة أمنية لإثبات ملكية الهاتف
- `mobile/lib/core/services/whatsapp_otp_service.dart:95-99`: توليد الرمز `generateOtpCode()` على الجهاز؛ التخزين في ذاكرة التطبيق `_activeOtps` (سطر 39)؛ والتحقق `verifyOtp` محلياً أيضاً.
- أي مهاجم يعدّل العميل (أو يستدعي منطق التحقق مباشرة) يتجاوز إثبات ملكية رقم الهاتف كلياً. يتقاطع مع `config.toml:59-61` حيث `[auth.sms] enable_signup = false` — أي لا يوجد تحقق هاتف بديل من مزوّد.
- **الإجراء:** توليد/تخزين/تحقق OTP يجب أن يتم server-side (Edge Function + جدول private مع HMAC ومهلة ومحاولات محدودة).

---

## 3. ملاحظات عالية الخطورة [عالي]

### ع-1: Edge Function `send-whatsapp-otp` — إرسال رسائل اعتباطي باسم النظام
- تقبل `phone` و`otpCode` من جسم الطلب (`send-whatsapp-otp/index.ts:22`) وترسل عبر جلسة OpenWA بمفتاح ثابت، مع CORS مفتوح `"Access-Control-Allow-Origin": "*"` (سطور 14-19).
- غير مدرجة في `config.toml` `[functions.*]` — لا ضبط صريح لـ `verify_jwt`. أي مستخدم مصادق (أو anon إن كان verify_jwt معطلاً) يستطيع إرسال رسائل واتساب لأي رقم على حساب التاجر (سبام/احتيال باسم «مُثبَت»).
- ملاحظة: تطبيق الموبايل لا يستدعي هذه الدالة أصلاً (يتصل بـ OpenWA مباشرة) — أي إنها كود ميت يحمل سراً حياً.

### ع-2: رفع المستندات يتحقق من «القراءة» فقط ثم يكتب بصلاحيات service_role
- `signed-document-upload/index.ts:10-14` و`finalize-document-upload/index.ts:9-13`: دالة `canAccessEntity` تتحقق من **SELECT** عبر عميل المستخدم (RLS) ثم تُنشئ جلسة الرفع وتُدرج في `files` و`ledger_entry_files`/`dispute_message_files` عبر `serviceClient()` (تتجاوز RLS).
- النتيجة: **العميل المرتبط (read-only حسب `docs/rls-matrix.md:8-14`) ودور `viewer` يستطيعان إرفاق ملفات بأي قيد أو رسالة نزاع يمكنهما قراءتها** — كتابة غير مقصودة وتعارض صريح مع مصفوفة الصلاحيات الموثقة.

### ع-3: باقة `business-assets` عامة وتسمح بـ SVG — XSS مخزّن محتمل
- `202607120004_storage_realtime.sql:19`: `('business-assets', ..., public=true, ..., array[...,'image/svg+xml'])`.
- ملفات SVG قد تحمل JavaScript؛ تقديمها من باقة عامة وعرضها في الواجهات = XSS مخزّن باسم نطاق التخزين. العمومية بحد ذاتها مقبولة للشعارات، لكن يجب حذف `image/svg+xml` من `allowed_mime_types` أو تعقيم المحتوى.

---

## 4. ملاحظات متوسطة [متوسط]

### م-1: دوال `security definer` بلا `set search_path` في 0012
- `private.trig_update_customer_currency_balance` (0012:52) و`public.command_create_ledger_entry` (0012:129) — عرضة لاختطاف search_path. كل الدوال الأخرى في المشروع مضبوطة `set search_path=''` (إيجابي)، وهاتان استثناء خطير.

### م-2: دوال عامة جديدة بلا `revoke` صريح من PUBLIC/anon
- الافتراضي في PostgreSQL يمنح `EXECUTE` لـ `PUBLIC` على الدوال الجديدة. الدوال المنشأة بعد 0003 — مثل `public.invite_business_member`، `public.respond_business_member_invite`، `public.create_statement` (0008:207-209)، `public.apply_customer_discount`، `public.post_manual_journal`، `public.close_accounting_period` (0010:505-507) — مُنحت لـ `authenticated` لكن **لم تُسحب من anon/PUBLIC**. الأثر محدود (الفحوص الداخلية ترفض بـ 42501 عند غياب `auth.uid()`)، لكنه يوسّع سطح الهجوم ويخالف انضباط default-deny الموثق.

### م-3: منح `usage on schema private` + EXECUTE على دوال `private.command_*` لـ authenticated
- `202607120003_rls_and_grants.sql:68-83` (وأيضاً 0008:210-213، 0010:508-511): المستخدمون المصادقون يستطيعون استدعاء دوال الأوامر الخاصة مباشرة، متجاوزين طبقة الـ wrapper العامة وأي منطق مستقبلي يُضاف إليها (rate limiting مثلاً). كما أن أي دالة private مستقبلية تُنشأ بلا revoke صريح قد تصبح قابلة للاستدعاء افتراضياً.

### م-4: تعارض صلاحيات التحديث مع مصفوفة الأدوار الموثقة
- `business_customers_update_staff` (0003:132-134) يسمح لأدوار `owner,admin,accountant,cashier` بتعديل `credit_limit` و`default_due_days` و`is_archived` (منح الأعمدة في 0003:49) — بينما `docs/rls-matrix.md:22` يقيد `cashier` بـ «إنشاء ديون وسداد فقط». أمين الصندوق يستطيع رفع حد ائتمان عميل أو أرشفته.

### م-5: سياسات قديمة لا تتحقق من قبول الربط (link_status)
- مايقريشن 0006 شدّد سياسات `ledger_entries` و`disputes` وملحقاتها باستبدالها بـ `can_customer_access_business_customer` الذي يشترط `link_status='linked'` (0006:486-513) — **إيجابي**.
- لكن سياساتي `ledger_state_select_allowed` و`confirmations_select_allowed` (0003:147-152) ما زالتا تستخدمان `private.can_access_ledger_entry` (0002:70-85) الذي يفحص `is_customer_owner` **دون** شرط الربط → عميل لم يقبل طلب الربط يمكنه قراءة حالة القيد (`ledger_entry_state`) وسجلات التأكيد (`entry_confirmations`) لقيود لا يمكنه قراءتها — تسريب معلومات محدود لكنه تضارب مع التشديد المقصود.

### م-6: جدول `upload_sessions` بلا revoke ولا policy
- `202608140006_platform_hardening_and_offline.sql:79-93` ينشئ الجدول، و522 يفعّل RLS، لكن سطر 523 (revoke) **لا يشمله**، ولا يوجد له أي `grant` أو `create policy`. الوضع الحالي: RLS بلا سياسة = رفض كامل (آمن لأن Edge Functions تستخدم service_role)، لكنه هش وغير متسق — ومع default privileges في Supabase قد يحمل منحاً غير مقصودة مستقبلاً.

### م-7: سياسة `customer_currency_balances` تقارن هوية خاطئة
- 0012:42: `customer_id = auth.uid()` — لكن العمود يخزّن `customers.id` (منسوخاً من `ledger_entries.customer_id`) لا `auth.users.id` → **العميل لن يرى أرصدة عملاته أبداً** (فشل تفويض وظيفي حتى لو أُصلحت المشاكل الحرجة). الصحيح استخدام `private.is_customer_owner(customer_id)`. كما لا توجد منح SELECT صريحة للجدول.

### م-8: بقايا تطوير في `config.toml`
- سطر 48: `additional_redirect_urls` يتضمن `http://127.0.0.1:3000` — يجب إزالته في الإنتاج.
- سطور 50-61: `enable_signup = true` مع تعطيل تسجيل البريد والهاتف معاً — مسار إنشاء الحسابات غير واضح ويعتمد فعلياً على مسار OTP الهش (انظر ح-5).

---

## 5. ملاحظات منخفضة [منخفض]

1. **صور Avatars مقيدة للمالك فقط** (0004:54-66): زملاء الفريق والعملاء لا يمكنهم رؤية صور بعضهم — قيد وظيفي قد يكون مقصوداً لكنه يستحق التوثيق.
2. **`reminders_update_staff`** (0003:188-190): أي عضو بالأدوار الخمسة يستطيع تعديل تذكيرات زملائه داخل نفس المحل وبأي حقل (بما فيه `business_id` نظرياً بين محلين يعضو فيهما) — يُفضّل تقييد الأعمدة أو المالك.
3. **`verify-statement` عام بلا JWT** (`config.toml:78-79`): تصميم مقبول — تحقق علني برمز `ST-` + 12 حرف hex (≈48 بت، 0008:161) مع rate limit ‏30/ساعة/IP (`verify-statement/index.ts:14`) — لكن لاحظ أن رمز التحقق جزء من مسار ملف الـ PDF (`generate-statement/index.ts:506`)؛ من يملك رابط الملف يملك الرمز ضمنياً.
4. **تغطية الاختبارات**: `tests/database/001_schema_contract.sql` يتحقق من *وجود* السياسات، و`002_core_workflow.sql` يغطي سيناريو سعيداً جزئياً — لا توجد اختبارات سلبية شاملة تثبت منع القراءة/الكتابة العابرة للمستأجرين لكل جدول ودور (خاصة viewer/collector وanon).

---

## 6. نقاط إيجابية [إيجابي]

1. **RLS مفعّل على كل الجداول العامة الـ 31** بلا استثناء (مطابقة كاملة بين `create table` و`enable row level security` عبر الملفات 0003:5-27، 0006:516-522، 0008:25، 0010:95-99، 0012:36).
2. **Default-deny منهجي**: `revoke all` على الجداول والتسلسلات والدوال من anon/authenticated (0003:30-33) ثم منح `select` فقط مع تحويل كل الكتابات إلى RPCs محصّنة.
3. **عزل PII الهاتف**: `private.customer_contacts` بتشفير AES-GCM + HMAC-SHA256 (0001:80-91) ولا يمر عبر Data API؛ البحث بالهاش فقط عبر دوال `service_*` المقيدة بـ `service_role` (0003:86-92).
4. **كل الـ views الخمسة** (`business_customer_balances`, `ledger_timeline`, `customer_business_summary`, `account_trial_balance`, `business_customer_account_positions`) تستخدم `security_invoker=true` (0002:653-679، 0010:465-480) — لا تجاوز لـ RLS عبر المالك.
5. **دوال `service_*` مقيدة بدقة**: revoke من public/anon/authenticated ومنح لـ `service_role` فقط (0003:86-92، 0005:148-159، 0006:550-557، 0008:214-217).
6. **دوال الأوامر محصّنة**: `security definer set search_path=''` مع فحوص أدوار داخلية صارمة (`is_business_member` بمصفوفات أدوار) في 0002/0006/0007/0008/0010 — مثال نموذجي: 0010:359.
7. **Storage منضبط**: باقات خاصة افتراضياً، لا سياسة INSERT مباشرة للعميل على `ledger-documents`/`statements` — الرفع عبر signed URL من Edge Function بعد فحص وصول، والقراءة مفوَّضة عبر جدول `files`/`statements` (0004:70-97)، مع حدود حجم (5/10MB) وأنواع MIME.
8. **Realtime محدود النطاق**: النشر مقتصر على `notifications, customer_link_requests, ledger_entry_state, dispute_state, dispute_messages` (0004:99-117) — لا جداول PII ولا قيود خام.
9. **عمال الخلفية محميون**: `process-notification-outbox` و`process-automation-rules` بلا JWT لكن مع `requireWorkerSecret` (`_shared/auth.ts:20-25`)، وCORS مقيد بـ `ALLOWED_ORIGIN` (`_shared/cors.ts:1-17`).
10. **لا أسرار في ملفات الإعداد**: `.env.example` placeholders فقط، لا ملف `.env` حقيقي في المشروع، `config.toml` نظيف، `jwt_expiry=3600`، `minimum_password_length=12`، و`verify_jwt=true` لكل الدوال الموثقة عدا الثلاثة المقصودة.

---

## 7. توصيات أولوية الإصلاح (قبل الإطلاق التجاري)

| # | الإجراء | المرتبط بـ |
|---|---------|-----------|
| 1 | إبطال مفتاح OpenWA فوراً ونقل كل منطق OTP/واتساب إلى الخادم | ح-1، ح-5، ع-1 |
| 2 | حذف/إعادة كتابة المايقريشن 0012 بالكامل: إصلاح السياسة، FK، enum، الوصف، وإضافة فحص الأدوار + revoke + search_path | ح-2، ح-3، ح-4، م-1، م-7 |
| 3 | تشديد `canAccessEntity` في دالتي الرفع إلى فحص دور كتابة (staff للقيود، طرف النزاع للرسائل) | ع-2 |
| 4 | إزالة `image/svg+xml` من باقة `business-assets` | ع-3 |
| 5 | توحيد سياسات `ledger_entry_state`/`entry_confirmations` على شرط الربط المقبول | م-5 |
| 6 | إضافة revoke صريح من PUBLIC/anon لكل دالة عامة جديدة، وتضييق منح schema private | م-2، م-3 |
| 7 | إضافة اختبارات pgTAP سلبية (cross-tenant read/write denied) لكل جدول ودور | منخفض-4 |

*انتهى التقرير — لم يُعدَّل أي ملف في المشروع.*
