# تقرير تدقيق عقود API بين الواجهات والباكند
## Frontend-Backend API Contract Audit — مشروع «مُثبَت» (دفتر ديون)

**المدقق:** مدقق_عقود_API_للواجهات
**النطاق:** `mobile/lib` (Flutter) ↔ `debt-ledger-supabase/supabase` (Migrations + Edge Functions)
**تاريخ التدقيق:** 2026 (وفق طابع الجلسة)
**منهجية العمل:** قراءة فعلية لكل ملفات Dart في `mobile/lib` (53 ملفاً) وكل ملفات migrations الـ 12، ومطابقة كل استدعاء بيانات (RPC / قراءة جدول / كتابة جدول / Edge Function / خدمة خارجية) مع ما يوفره الباكند فعلياً من دوال عامة ومنح (grants) وسياسات RLS.

---

## 1. ملخص تنفيذي

الفجوة بين الواجهة والباكند **جذرية وليست هامشية**. الباكند مبني بمعمارية «أوامر عبر RPC + قراءة عبر RLS» منضبطة، لكن الواجهة Flutter تستدعي أسماء دوال ومعاملات **لا توجد** في الباكند، وتلتف حول الأخطاء ببلوكات `try/catch` تبتلع الفشل بصمت، فتبدو التطبيق «يعمل» بينما لا يصل أي شيء فعلياً إلى السحابة. شاشة العميل بأكملها بيانات وهمية ثابتة، ولا يوجد أي استدعاء واحد لأي من الـ 9 Edge Functions. مسار الأوفلاين (طابور المزامنة) مبني بعناية محلياً لكن كل حمولاته (payloads) غير متوافقة مع تواقيع الـ RPC، أي أن **كل عملية مالية تُسجَّل في التطبيق لن تُزامَن أبداً بنجاح**.

**الحكم:** بصيغته الحالية، التطبيق أقرب إلى نموذج عرض (demo) يعمل على SQLite محلي؛ التكامل الفعلي مع الباكند شبه معدوم. **غير صالح للإطلاق التجاري** قبل معالجة الملاحظات الحرجة.

| التصنيف | العدد |
|---|---|
| [حرج] | 15 |
| [عالي] | 7 |
| [متوسط] | 7 |
| [منخفض] | 3 |
| [إيجابي] | 4 |

---

## 2. جرد سطح API الذي يوفره الباكند فعلياً

### 2.1 دوال RPC العامة (public) الممنوحة لـ `authenticated`

المصدر: `supabase/migrations/202607120002_functions_and_triggers.sql` و`202607120003_rls_and_grants.sql` (أسطر 56–65) و`202608140008` (أسطر 207–209) و`202608140010` (أسطر 505–507):

| RPC العام | التوقيع (المعاملات) | ملف التعريف |
|---|---|---|
| `create_business` | `(p_name, p_business_type, p_currency_code, p_country_code, p_city, p_address)` | 0002:174 |
| `add_business_customer` | `(p_business_id, p_customer_id, p_local_display_name, p_credit_limit, p_default_due_days)` | 0002:226 |
| `request_customer_link` | `(p_business_customer_id)` | 0002:263 |
| `respond_link_request` | `(p_request_id, p_accept)` | 0002:294 |
| `create_ledger_entry` | `(p_business_customer_id, p_entry_type, p_amount, p_description, p_occurred_at, p_due_date, p_external_reference, p_client_request_id, p_source_device_id)` | 0002:413 |
| `reverse_ledger_entry` | `(p_entry_id, p_reason, p_client_request_id)` | 0002:453 |
| `confirm_ledger_entry` | `(p_entry_id, p_device_id)` | 0002:496 |
| `open_dispute` | `(p_entry_id, p_reason, p_description)` | 0002:530 |
| `add_dispute_message` | `(p_dispute_id, p_message)` | 0002:563 |
| `resolve_dispute` | `(p_dispute_id, p_resolution, p_resolution_note, p_corrected_amount)` | 0002:606 |
| `invite_business_member` | `(p_business_id, p_target_user_id, p_role, p_expires_at)` | 0008:60 |
| `respond_business_member_invite` | `(p_invite_id, p_accept)` | 0008:91 |
| `create_statement` | `(p_scope, p_business_customer_id, p_period_from, p_period_to)` | 0008:185 |
| `apply_customer_discount` | `(p_business_customer_id, p_amount, p_description, p_occurred_at, p_client_request_id)` | 0010:404 |
| `post_manual_journal` | `(p_business_id, p_entry_date, p_description, p_lines, p_source_reference)` | 0010:438 |
| `close_accounting_period` | `(p_business_id, p_period_start, p_period_end)` | 0010:461 |
| `command_create_ledger_entry` (متعدد العملات) | `(p_business_customer_id, p_entry_type, p_amount, p_currency_code, p_category, p_payment_method, p_reference_number, p_bank_or_agent_name, p_description, p_occurred_at, p_due_date, p_external_reference, p_client_request_id, p_source_device_id)` | 0012:114 — **انظر الملاحظة الحرجة C-6: هذه الـ migration مكسورة ولا تُطبَّق** |

ملاحظة معمارية: كل دوال `private.command_*` ممنوحة `execute` لـ `authenticated` (0003:74–83)، لكن مخطط `private` **ليس مكشوفاً عبر PostgREST** (التعليق نفسه في 0003:67 يقول: "private is not an exposed API schema")، فلا يمكن استدعاؤها من العميل إطلاقاً.

### 2.2 الجداول/العروض المقروءة مباشرة (SELECT عبر RLS)

منحة SELECT (0003:36–44) تشمل: `profiles, customers, businesses, business_members, business_customers, customer_link_requests, ledger_entries, ledger_entry_state, ledger_entry_events, entry_confirmations, disputes, dispute_state, dispute_events, dispute_messages, files, notifications, reminders, statements, statement_items, user_consents` + العروض `business_customer_balances, ledger_timeline, customer_business_summary` (0002:653–683) و`account_trial_balance, business_customer_account_positions` (0010:465–490).

الكتابة المباشرة المسموحة محدودة جداً (0003:47–53): تحديث أعمدة محددة في `profiles` (بدون INSERT)، `businesses`، `business_customers`، و`device_push_tokens/notifications.read_at/reminders/user_consents`.

### 2.3 Edge Functions (9)

`bootstrap-user-contact, customer-directory, finalize-document-upload, generate-statement, process-automation-rules, process-notification-outbox, send-whatsapp-otp, signed-document-upload, verify-statement`.

---

## 3. جرد شامل: كل استدعاء بيانات في الواجهات (مصنّف)

### 3.1 استدعاءات RPC من الواجهة

| # | الموقع في الواجهة | الاستدعاء | التصنيف | الحالة |
|---|---|---|---|---|
| R1 | `core/sync/sync_engine.dart:123` | `rpc('create_ledger_entry', payload)` | API آمن (الاسم صحيح) | ❌ **معاملات خاطئة** — انظر C-2 |
| R2 | `core/sync/sync_engine.dart:125` | `rpc('apply_customer_discount', payload)` | API آمن (الاسم صحيح) | ❌ معامل زائد `p_currency_code` — C-4 |
| R3 | `core/sync/sync_engine.dart:127` | `rpc('reverse_ledger_entry', payload)` | API آمن (الاسم صحيح) | ❌ معامل `p_original_entry_id` بدل `p_entry_id` — C-3 |
| R4 | `core/sync/sync_engine.dart:129` | `rpc('confirm_ledger_entry', payload)` | API آمن | ⚠️ مسار ميت: لا أحد يُدرج هذا الأمر في الطابور — H-6 |
| R5 | `core/sync/sync_engine.dart:131` | `rpc('open_dispute', payload)` | API آمن | ⚠️ مسار ميت — H-6 |
| R6 | `features/merchant/data/merchant_repository.dart:349` | `rpc('command_add_dispute_message', …)` | ❌ **RPC غير موجود** — C-1 |
| R7 | `features/merchant/data/merchant_repository.dart:367` | `rpc('command_resolve_dispute', …)` | ❌ **RPC غير موجود** — C-1 |
| R8 | `features/merchant/data/merchant_repository.dart:422` | `rpc('command_invite_business_member', …)` | ❌ **RPC غير موجود** + معاملات خاطئة — C-1 / H-3 |
| R9 | `features/merchant/data/merchant_repository.dart:452` | `rpc('command_generate_statement', …)` | ❌ **RPC غير موجود** + قيمة scope خاطئة — C-1 / H-2 |
| R10 | (غير موجود) | `create_business` | — | ❌ **لا يُستدعى إطلاقاً** — C-8 |
| R11 | (غير موجود) | `add_business_customer` | — | ❌ **لا يُستدعى إطلاقاً** — C-5 |

### 3.2 قراءات مباشرة على الجداول (SELECT عبر PostgREST/RLS)

| # | الموقع | الجدول | الحالة |
|---|---|---|---|
| T1 | `merchant_repository.dart:294-302` | `disputes` + تضمين `dispute_state, ledger_entries, profiles!customer_id` | ❌ تضمين `profiles!customer_id` غير صالح — C-13 |
| T2 | `merchant_repository.dart:332-338` | `dispute_messages` + تضمين `profiles(display_name)` | ❌ لا يوجد FK من `dispute_messages` إلى `profiles` — C-14 |
| T3 | `merchant_repository.dart:385-391` | `business_members` بأعمدة `member_role, permissions, is_active` | ❌ أعمدة غير موجودة (الفعلية `role, status`) — C-12 |
| T4 | `merchant_repository.dart:403-406` | `business_member_invites` | ✅ متوافق (0008:6-17 + منحة SELECT 0008:27) |
| T5 | `merchant_repository.dart:460-464` | `statements` | ✅ متوافق (قراءة مسموحة بالـ RLS 0003:192) |
| T6 | `core/sync/sync_engine.dart:156-160` | `business_members` مع `businesses(*)` و`status='active'` | ✅ متوافق بنيوياً |
| T7 | `core/sync/sync_engine.dart:179-183` | `business_customers` مع `customers(global_code)` | ✅ متوافق، لكن `phone` غير موجود بالباكند — M-2 |
| T8 | `core/sync/sync_engine.dart:187-191` | `business_customer_balances` (view) | ✅ متوافق (0002:653) — لكن بنمط N+1 — M-6 |
| T9 | `features/auth/.../auth_controller.dart:117-121` | `profiles` بعمود `user_type` | ❌ عمود غير موجود — C-11 |

### 3.3 كتابات مباشرة على الجداول

| # | الموقع | العملية | الحالة |
|---|---|---|---|
| W1 | `auth_controller.dart:230-235` | `from('profiles').upsert({id, display_name, user_type, phone})` | ❌ أعمدة `user_type/phone` غير موجودة + لا منحة INSERT على `profiles` — C-11 |
| W2 | `auth_controller.dart:416-421` | نفس الـ upsert عند تحقق OTP | ❌ نفس المشكلة — C-11 |

### 3.4 استدعاءات Edge Functions

**لا يوجد ولا استدعاء واحد**: البحث عن `functions.invoke` في كل `mobile/lib` = صفر نتائج. كل الدوال الـ 9 غير مستخدمة — H-1.

### 3.5 خدمات خارجية مباشرة (خارج الباكند)

| # | الموقع | الخدمة | الحالة |
|---|---|---|---|
| X1 | `core/services/whatsapp_otp_service.dart:28-36, 161-171` | خادم OpenWA محلي (`192.168.0.134:2785`) بمفتاح API مضمّن في الكود | ❌ يلتف على Edge Function `send-whatsapp-otp` — C-10 |

### 3.6 بيانات محلية بحتة (لا تلامس الباكند إطلاقاً)

| # | الموقع | ما يحدث |
|---|---|---|
| L1 | `merchant_repository.dart:19-43` | `getCustomers/getCustomer/getLedgerEntries` تقرأ SQLite فقط |
| L2 | `merchant_repository.dart:46-81` | `addCustomer` يحفظ محلياً فقط، **بلا RPC وبلا إدراج في طابور المزامنة** — C-5 |
| L3 | `core/database/app_database.dart:379-460` | حساب الأرصدة متعددة العملات **محلياً** عند كل قيد |
| L4 | `features/merchant/presentation/controllers/merchant_controller.dart:118-134` | تجميع إجماليات لوحة التاجر (لك/عليك) **محلياً** من الكاش |
| L5 | `features/customer/presentation/screens/customer_home_screen.dart:93-104, 181-195` | **شاشة العميل كلها بيانات ثابتة وهمية** — C-8 |
| L6 | `auth_controller.dart:104, 131-137, 155, 214, 254` | معرفات وهمية `usr-<phone>` / `biz-<userId>` وملفات محلية بديلة عند فشل المصادقة — C-9 |

---

## 4. الملاحظات الحرجة [حرج]

### C-1 — أربعة استدعاءات RPC بأسماء غير موجودة في الباكند [حرج]
- **المواقع:** `merchant_repository.dart:349` (`command_add_dispute_message`)، `:367` (`command_resolve_dispute`)، `:422` (`command_invite_business_member`)، `:452` (`command_generate_statement`).
- **الحقيقة في الباكند:** الأسماء العامة هي `add_dispute_message` (0002:563)، `resolve_dispute` (0002:606)، `invite_business_member` (0008:60)، `create_statement` (0008:185). أسماء `command_*` موجودة فقط في مخطط `private` غير المكشوف عبر PostgREST (0003:67).
- **الأثر:** كل استدعاء يرمي خطأ `PGRST202`، يُبتلع في `catch` ويعيد `false`/`null` بصمت. النتيجة: **إرسال رسائل النزاع، حل النزاع، دعوة الموظفين، وإصدار كشوفات الحساب — كلها معطلة وظيفياً 100%** رغم أن الواجهة تعرض رسائل نجاح/فشل مضللة.

### C-2 — `create_ledger_entry`: حمولة المزامنة لا تطابق توقيع الدالة [حرج]
- **المواقع:** الحمولة تُبنى في `merchant_repository.dart:129-143` وتُرسل في `sync_engine.dart:123`.
- **التفاصيل:** الواجهة ترسل `p_currency_code, p_category, p_payment_method, p_reference_number, p_bank_or_agent_name, p_attachment_path` — وكلها **غير موجودة** في توقيع `public.create_ledger_entry` (0002:413-425: تسعة معاملات فقط، بلا عملة/تصنيف/سداد/مرفق). PostgREST يطابق الدالة بالاسم+المعاملات → `PGRST202 Could not find the function`.
- **الأثر:** **كل قيد دين/سداد يُسجَّل في التطبيق يبقى في `offline_mutations_queue` للأبد** ولا يصل قاعدة البيانات. الدالة متعددة العملات التي تستحق هذه المعاملات سُمّيت `command_create_ledger_entry` (0012:114) ولا يستدعيها أحد — وهي نفسها مكسورة (C-6).

### C-3 — `reverse_ledger_entry`: اسم معامل خاطئ [حرج]
- **الموقع:** `merchant_repository.dart:259-263` يرسل `p_original_entry_id`؛ الدالة تتوقع `p_entry_id` (0002:453).
- **الأثر:** عكس القيود لا يُزامَن أبداً.

### C-4 — `apply_customer_discount`: معامل زائد [حرج]
- **الموقع:** `merchant_repository.dart:190-196` يرسل `p_currency_code`؛ التوقيع العام (0010:404-408) لا يقبله.
- **الأثر:** الخصومات لا تُزامَن أبداً.

### C-5 — إضافة عميل جديد لا تصل الباكند إطلاقاً [حرج]
- **الموقع:** `merchant_repository.dart:46-81` (`addCustomer`).
- **التفاصيل:** لا استدعاء لـ `add_business_customer` (0002:226)، ولا إدراج في `offline_mutations_queue` (الإدراج يحدث فقط داخل `saveLedgerEntryOptimistic`، `app_database.dart:463-473`). المعرف المحلي `'cust-${uuid}'` (سطر 54) ليس UUID صالحاً، ولو أُرسل كـ `p_business_customer_id` لفشل التحويل. كما أن الباكند يشترط `customer_id` يشير إلى `public.customers` (0001:126) والواجهة لا تنشئ سجل عميل إطلاقاً.
- **الأثر:** كل قيد لاحق على هذا العميل ميت أيضاً، لأن `business_customer_id` غير موجود في الباكند. سلسلة كسر كاملة: عميل → قيود → أرصدة → كشوفات.

### C-6 — Migration 12 (تعدد العملات) مكسورة ولا يمكن تطبيقها [حرج]
- **الموقع:** `202608180012_multi_currency_and_categories.sql:41` يستخدم `public.has_business_permission(...)` ونوع `public.business_permission` — **وكلاهما غير معرَّف في أي migration** (بحث شامل في المجلد: لا تعريف).
- **تفاصيل إضافية داخل نفس الملف:** الدالة `command_create_ledger_entry` تدرج `direction` بالقيم `'in'/'out'` (أسطر 59-64) بينما `public.ledger_direction` هو `('debit','credit')` (0001:20)؛ وتستخدم نوع قيد `'fee'` (سطر 157) غير الموجود في `ledger_entry_type` (0001:19 + 0009 تضيف `discount` فقط)؛ و`p_source_device_id text` (سطر 128) بينما العمود `uuid` (0001:173)؛ و`customer_currency_balances.customer_id` يشير إلى `public.profiles(id)` (سطر 17) بينما كل النظام يشير إلى `public.customers`.
- **الأثر:** فشل الـ migration يعني أن جدول `customer_currency_balances` ودالة الإدخال متعددة العملات **غير موجودين في قاعدة البيانات المنشورة** — أي أن ميزة تعدد العملات في الواجهة بلا أي سند خلفي.

### C-7 — تضارب منطقي: تعدد العملات في الواجهة مقابل قيد العملة الواحدة في الباكند [حرج]
- **المواقع:** الواجهة تتيح YER/SAR/USD (`customer_ledger_screen.dart:33-37, 363-369`؛ `create_ledger_entry_sheet.dart:90`)؛ الباكند `private.validate_ledger_entry_insert` (0010:329-330) يرفض أي قيد عملته ≠ عملة المحل: `if v_currency is null or v_currency<>new.currency_code then raise exception 'Currency or business status mismatch'`.
- **الأثر:** حتى لو أُصلحت أسماء الـ RPC، أي قيد بعملة غير عملة المحل سيُرفض. قرار منتج/معماري مطلوب.

### C-8 — شاشة العميل بأكملها بيانات وهمية ثابتة [حرج]
- **الموقع:** `features/customer/presentation/screens/customer_home_screen.dart`.
- **التفاصيل:** الرصيد الإجمالي ثابت `'450,000 ر.ي'` (سطر 94)، «مرتبط بـ 2 محلات» (سطر 103)، بطاقتا محلان بأسماء وأرصدة ثابتة (أسطر 181-195)، طلب ربط وهمي (أسطر 141-147)، وزر «تأكيد السجل» يعرض SnackBar نجاح **بدون أي استدعاء** (أسطر 264-272). لا قراءة من `customer_business_summary` (0002:678)، ولا استدعاء `confirm_ledger_entry`/`respond_link_request`/`open_dispute`/`create_statement(customer_consolidated)`.
- **الأثر:** كل تجربة العميل (تأكيد القيود، الرد على طلبات الربط، فتح النزاعات، الكشف المجمع) — وهي جوهر قيمة المنتج «غير القابل للإنكار» — **غير منفذة**.

### C-9 — المصادقة تلتف حول الباكند وتصنع هويات وهمية [حرج]
- **المواقع:** `auth_controller.dart:104` (`usr-<phone>`)، `:155` و`:254` و`:444` (`biz-<userId>`)، `:128-138` (السقوط للكاش المحلي عند فشل Supabase).
- **التفاصيل:** عند فشل `signInWithPassword` يُقبل الدخول من الكاش المحلي بهوية مفبركة غير موجودة في `auth.users`؛ المحل يُنشأ محلياً فقط ولا يُستدعى `create_business` إطلاقاً. كل استدعاء RPC لاحق سيفشل (لا جلسة، أو لا عضوية `business_members`).
- **الأثر:** انفصال كامل بين «المستخدم المسجَّل دخوله» وأي صف في الباكند.

### C-10 — OTP عبر خادم محلي مباشر مع مفتاح مضمّن + كود تجاوز ثابت [حرج]
- **المواقع:** `whatsapp_otp_service.dart:28-29` (sessionId وapiKey ثابتان في الكود)، `:32-36` (عناوين LAN/localhost)، `:196-199` (قبول `123456`/`000000` دائماً)، و`auth_controller.dart:397` (قبول `state.mockOtpCode`).
- **التفاصيل:** الباكند يوفر Edge Function `send-whatsapp-otp` (بنفس إعدادات OpenWA كمتغيرات بيئة) لكن الواجهة لا تستدعيها. التحقق يتم محلياً ضد ذاكرة التطبيق، وأي شخص يعرف `123456` يدخل أي حساب.
- **الأثر:** كسر أمني كامل لطبقة المصادقة + تسريب مفتاح API في حزمة التطبيق.

### C-11 — كتابة/قراءة `profiles` بأعمدة غير موجودة وبدون منحة INSERT [حرج]
- **المواقع:** `auth_controller.dart:118-119` (select `user_type`)، `:230-235` و`:416-421` (upsert بـ `user_type, phone`).
- **الحقيقة:** جدول `profiles` (0001:58-67) أعمدته: `id, display_name, avatar_path, city, preferred_language, status, created_at, updated_at` — لا `user_type` ولا `phone`. والمنح (0003:47) تسمح بـ `update(display_name,avatar_path,city,preferred_language)` فقط — **لا INSERT**، والـ upsert سيفشل بـ `42501`. التريجر `handle_new_auth_user` (0002:114-138) ينشئ الملف تلقائياً عند التسجيل، فالـ upsert غير مطلوب أصلاً.
- **الأثر:** «نوع المستخدم» (تاجر/عميل) لا يُحفظ ولا يُقرأ من الباكند أبداً؛ التوجيه بين واجهتي التاجر والعميل يعتمد على كاش محلي قابل للتلاعب.

### C-12 — `getMembers` يقرأ أعمدة غير موجودة → شاشة الفريق فارغة دائماً [حرج]
- **الموقع:** `merchant_repository.dart:385-391` يطلب `member_role, permissions, is_active`؛ الأعمدة الفعلية في `business_members` (0001:111-121) هي `role, status`.
- **الأثر:** PostgREST يرمي `42703` → `catch` → قائمة فارغة. شاشة `team_screen.dart` لا تعرض أي عضو أونلاين أبداً.

### C-13 — `getDisputes`: تضمين علاقة غير موجودة [حرج]
- **الموقع:** `merchant_repository.dart:295-300` يضمّن `profiles!customer_id (display_name, phone)`؛ لكن `disputes.customer_id` يشير إلى `public.customers(id)` (0001:220) وليس `profiles`، ولا يوجد FK بهذا الاسم.
- **الأثر:** فشل الاستعلام كاملاً → سقوط إلى `local_disputes` الفارغة → قائمة النزاعات لا تعمل أونلاين. (ملاحظة ثانوية: `customers` لا يملك `display_name/phone` أصلاً — الهاتف مشفّر في `private.customer_contacts` غير المكشوف).

### C-14 — `getDisputeMessages`: تضمين `profiles` بلا مفتاح أجنبي [حرج]
- **الموقع:** `merchant_repository.dart:333-336`؛ `dispute_messages.sender_user_id` يشير إلى `auth.users` (0001:251) ولا يوجد FK مباشر إلى `profiles`.
- **الأثر:** الاستعلام يفشل → `catch` → `[]` → محادثة النزاع فارغة دائماً (`dispute_detail_screen.dart:46-57`).

### C-15 — المرفقات لا تُرفع إلى Storage إطلاقاً [حرج]
- **المواقع:** `attachment_picker_widget.dart` (لا يوجد أي استدعاء `storage`)؛ المسار المحلي للملف يُمرَّر كـ `p_attachment_path` (`create_ledger_entry_sheet.dart:84` → `merchant_repository.dart:138`) وهو معامل غير موجود أصلاً (C-2)، والعمود الخلفي اسمه `attachment_url` (0012:10).
- **الأثر:** «سند موثق بالمرفقات» غير موجود فعلياً؛ باكند يوفر `signed-document-upload` و`finalize-document-upload` و`upload_sessions` (0006:79) — كلها غير مستخدمة.

---

## 5. ملاحظات عالية الخطورة [عالي]

### H-1 — صفر استدعاءات لكل Edge Functions التسع [عالي]
`functions.invoke` غير موجودة في كل كود الواجهة. الأثر لكل دالة:
- `generate-statement`: لا يُولَّد أي PDF ولا `snapshot_sha256_hex` → `statement.downloadUrl` دائماً `null` (`statement_preview_screen.dart:223` يخفي زر التحميل دائماً) و«الختم SHA-256» المعروض في `generate_statement_sheet.dart:128` غير حقيقي.
- `verify-statement`: لا يوجد في الواجهة أي شاشة/حقل للتحقق برمز الكشف.
- `send-whatsapp-otp`: متجاوَز (C-10).
- `bootstrap-user-contact`: لا يُشفَّر ولا يُسجَّل هاتف العميل في `private.customer_contacts` → `service_find_customer_by_phone_hash` عديم الجدوى → ربط العملاء بالهاتف مستحيل.
- `customer-directory, process-notification-outbox, process-automation-rules, signed-document-upload, finalize-document-upload`: غير مربوطة بالواجهة.

### H-2 — قيمة `p_scope` خاطئة في توليد الكشف [عالي]
`merchant_repository.dart:453` يرسل `p_scope: 'customer'`؛ الـ enum `statement_scope` (0001:31) قيمتاه `'business_customer'` و`'customer_consolidated'`. حتى بعد تصحيح اسم الدالة إلى `create_statement` سيفشل التحويل للـ enum.

### H-3 — `inviteMember` يرسل هاتفاً في خانة معرّف مستخدم [عالي]
`merchant_repository.dart:422-426` يرسل `p_phone` بينما `invite_business_member` (0008:60-64) يتوقع `p_target_user_id uuid`. والأسوأ: `invite_member_sheet.dart:114-132` يطلب من المستخدم «المعرف الرقمي User ID» ثم `merchant_repository.dart:424` يرسله كـ `p_phone` — خلط مفاهيمي كامل.

### H-4 — المزامنة لا تسحب القيود ولا الأرصدة متعددة العملات ولا النزاعات [عالي]
`sync_engine.dart:147-220` (`_pullRemoteUpdates`) يسحب فقط `businesses` و`business_customers` ورصيداً واحداً مسطحاً. لا سحب لـ `ledger_entries` (الواجهة تقرأها من الكاش فقط — `merchant_repository.dart:40-43`)، ولا لـ `customer_currency_balances`، ولا لـ `disputes` ضمن المزامنة. النتيجة: جهاز ثانٍ لنفس التاجر **لن يرى أي قيد**، والأرصدة تُحسب محلياً وتتباين بين الأجهزة.

### H-5 — تجاهل بنية الأوفلاين التي بناها الباكند [عالي]
Migration 0006 يوفر `command_receipts` (إيصالات idempotency)، `sync_checkpoints`، `device_installations` (أسطر 5-39) و`command_receipts_command_type_check` يشمل كل الأوامر (0011:5-10). الواجهة لا تسجّل جهازاً ولا تستخدم checkpoints ولا تقرأ الإيصالات؛ تعتمد فقط على `client_request_id` وتعيد المحاولة بلا سقف (`sync_engine.dart:136-142` — الطابور قد يعلق للأبد مع `attempt_count` بلا حد).

### H-6 — مسارات ميتة في محرك المزامنة [عالي]
`sync_engine.dart:128-132` يعالج `confirm_ledger_entry` و`open_dispute`، لكن **لا يوجد أي كود في التطبيق يُدرج هذين النوعين في الطابور** (الإدراج الوحيد في `saveLedgerEntryOptimistic` بثلاثة أنواع فقط). وظيفتا تأكيد العميل وفتح النزاع — عمودا المنتج — غير موصولتين من الأساس (مرتبط بـ C-8).

### H-7 — عمليات النزاع لا تعمل أوفلاين وتفشل بصمت [عالي]
`addDisputeMessage` و`resolveDispute` (`merchant_repository.dart:346-377`) مباشرة أونلاين فقط، بلا طابور، وتعيد `false` عند أي خطأ؛ والواجهة تعرض «تحقق من اتصالك» بينما السبب الحقيقي اسم RPC خاطئ (C-1) — تشخيص مستحيل للمستخدم والدعم.

---

## 6. ملاحظات متوسطة [متوسط]

- **M-1** `full_schema.sql` يحتوي تعريفات مكررة ومتضاربة (مثلاً `private.command_resolve_dispute` ثلاث مرات: أسطر 1022 و2066 و2286) — لا يُعتمد كمرجع مخطط، وخطر استخدامه لنشر بيئة جديدة.
- **M-2** `sync_engine.dart:179-213`: `business_customers` في الباكند لا يملك عمود `phone`؛ `BusinessCustomerModel.phone` (`business_customer_model.dart:74`) سيكون `null` دائماً من السحابة، وشاشة القيد تعرض «بدون رقم مسجل» (`customer_ledger_screen.dart:253`).
- **M-3** نوع القيد `'fee'` مستخدم في `app_database.dart:405` وفي 0012:157 لكنه غير موجود في `ledger_entry_type` — حسابات محلية وخلفية لنوع شبح.
- **M-4** `customer_currency_balances.customer_id → public.profiles(id)` (0012:17) يكسر الاتساق المرجعي مع `ledger_entries.customer_id → public.customers(id)` (0001:162).
- **M-5** نمط N+1 في المزامنة: استعلام رصيد منفصل لكل عميل (`sync_engine.dart:185-191`) + مزامنة دورية كل 30 ثانية (`:54`) — حمل شبكة/بطارية مرتفع مع نمو العملاء.
- **M-6** عند نجاح مزامنة قيد، لا يُحدَّث `sync_status` للقيد المحلي إلى `synced` (`sync_engine.dart:135` يحذف من الطابور فقط) — الواجهة تبقى تعرض شارة «معلق» (`customer_ledger_screen.dart:624-638`) رغم نجاح الإرسال.
- **M-7** `loginWithPassword` يقرأ `user_type` من `profiles` (`auth_controller.dart:119`) — عمود غير موجود؛ الاستعلام داخل نفس `try` الخاص بالمصادقة فيسقط كله إلى مسار الكاش الوهمي (C-9) حتى عند نجاح تسجيل الدخول الفعلي.

## 7. ملاحظات منخفضة [منخفض]

- **L-1** تعليقات النماذج تذكر قيماً غير مدعومة خلفياً: `payment_method: 'offset'` (`ledger_entry_model.dart:11`) وأسباب نزاع `incorrect_amount/duplicate_entry/...` (`dispute_model.dart:6, 87-103`) لا تطابق enum الباكند `dispute_reason` الفعلي `('wrong_amount','unknown_transaction','duplicate','already_paid','wrong_date','wrong_description','other')` (0001:24) — عند ربط فتح النزاع مستقبلاً ستفشل القيم المرسلة.
- **L-2** `MemberModel` يتوقع `role`/`status` (صحيح) لكن `getMembers` يطلب أعمدة أخرى (C-12) — النموذج والاستعلام منسوبان لمخططين مختلفين.
- **L-3** `SupabaseConfig` (`supabase_config.dart:8-13`) مفتاح anon افتراضي وهمي وعنوان `127.0.0.1:55321` — بلا آلية بيئات (dev/staging/prod) معتمدة؛ خطر شحن إعدادات تطوير للإنتاج.

## 8. نقاط إيجابية [إيجابي]

- **P-1** حدود API في الباكند منضبطة: `revoke all` افتراضي ثم منح SELECT فقط على الجداول، وكل الكتابة عبر command RPCs بـ `security definer` و`search_path=''` (0003:29-65) — التصميم الخلفي سليم ومؤسس جيداً.
- **P-2** الواجهة تستخدم القراءة المباشرة المسموحة (SELECT عبر RLS) ولا تحاول كتابة مباشرة في الجداول المحصّنة (باستثناء `profiles` — C-11) — الاتجاه المعماري صحيح حيث طُبّق.
- **P-3** idempotency عبر `client_request_id` مطبق في الطرفين: `unique (business_id, client_request_id)` (0001:176) وإعادة الاستعلام عن المفتاح في 0010:360-361، والواجهة تولّد UUID لكل أمر (`merchant_repository.dart:99`).
- **P-4** أسماء RPC الخمسة الأساسية في `sync_engine.dart:122-132` تطابق الباكند حرفياً (`create_ledger_entry, apply_customer_discount, reverse_ledger_entry, confirm_ledger_entry, open_dispute`) — الأساس الصحيح موجود ويحتاج فقط تصحيح المعاملات.

---

## 9. مصفوفة التطابق النهائي (عملية ↔ واجهة ↔ باكند)

| العملية | الواجهة تستدعي | الباكند يوفر | الحكم |
|---|---|---|---|
| إنشاء محل | — (محلي فقط) | `create_business` | ❌ غير موصول |
| إضافة عميل | — (محلي فقط) | `add_business_customer` | ❌ غير موصول |
| قيد دين/سداد | `create_ledger_entry` بمعاملات زائدة | `create_ledger_entry` (9 معاملات) / `command_create_ledger_entry` (مكسور) | ❌ معاملات |
| خصم | `apply_customer_discount` + `p_currency_code` | `apply_customer_discount` (بلا عملة) | ❌ معاملات |
| عكس قيد | `reverse_ledger_entry` + `p_original_entry_id` | `reverse_ledger_entry(p_entry_id,…)` | ❌ اسم معامل |
| تأكيد قيد (عميل) | — (زر وهمي) | `confirm_ledger_entry` | ❌ غير منفذ |
| فتح نزاع (عميل) | — | `open_dispute` | ❌ غير منفذ |
| رسالة نزاع | `command_add_dispute_message` | `add_dispute_message` | ❌ اسم |
| حل نزاع | `command_resolve_dispute` | `resolve_dispute` | ❌ اسم |
| دعوة موظف | `command_invite_business_member` + `p_phone` | `invite_business_member(p_target_user_id,…)` | ❌ اسم + معاملات |
| الرد على دعوة | — | `respond_business_member_invite` | ❌ غير منفذ |
| طلب/رد ربط عميل | — | `request_customer_link` / `respond_link_request` | ❌ غير منفذ |
| كشف حساب | `command_generate_statement` + scope `'customer'` | `create_statement` + enum `('business_customer','customer_consolidated')` | ❌ اسم + قيمة |
| PDF الكشف | — | Edge `generate-statement` | ❌ غير موصول |
| التحقق من كشف | — | Edge `verify-statement` | ❌ غير موصول |
| OTP واتساب | خادم OpenWA محلي مباشر | Edge `send-whatsapp-otp` | ❌ التفاف |
| رفع مرفقات | — (مسار محلي) | Edge `signed-document-upload` / `finalize-document-upload` + Storage | ❌ غير موصول |
| دليل العملاء بالهاتف | — | Edge `customer-directory` + `bootstrap-user-contact` | ❌ غير موصول |
| قيد يدوي محاسبي | — | `post_manual_journal` | ⚪ ميزة بلا واجهة (مقبول للـ MVP) |
| إغلاق فترة محاسبية | — | `close_accounting_period` | ⚪ ميزة بلا واجهة (مقبول للـ MVP) |

---

## 10. توصيات مرتبة بالأولوية

1. **توحيد أسماء الـ RPC فوراً** (C-1): إما تصحيح الواجهة إلى `add_dispute_message / resolve_dispute / invite_business_member / create_statement`، أو إضافة wrappers عامة بالأسماء التي تتوقعها الواجهة. الأول أصح.
2. **تثبيت عقد `create_ledger_entry` واحد**: إصلاح migration 12 (تعريف `has_business_permission`/`business_permission` أو استبدالها بـ `private.is_business_member`، وتصحيح `direction` إلى `debit/credit`، وإسقاط `fee`) ثم جعل الواجهة تستدعي الاسم والتوقيع النهائيين نفسهما — وحسم قرار تعدد العملات مقابل قيد 0010:329-330 (C-7).
3. **تصحيح المعاملات**: `p_entry_id` للعكس (C-3)، إسقاط `p_currency_code` من الخصم أو توسيع الدالة (C-4)، `p_target_user_id` للدعوات (H-3)، scope صحيح للكشوفات (H-2).
4. **ربط إضافة العميل بالباكند** (C-5): استدعاء `add_business_customer` (مع سياسة إنشاء `customers` عبر `bootstrap-user-contact`/دليل الهاتف) وإدراج الأمر في طابور المزامنة، واستبدال المعرفات `cust-*/biz-*/usr-*` بمعرفات راجعة من الباكند.
5. **تنفيذ واجهة العميل فعلياً** (C-8, H-6): ربط `customer_business_summary`، `confirm_ledger_entry`، `respond_link_request`، `open_dispute`، وإدراج أوامر العميل في الطابور.
6. **إغلاق ثغرات المصادقة** (C-9, C-10, C-11): منع الدخول بدون جلسة Supabase حقيقية، حذف كودي `123456/000000`، نقل OTP إلى Edge Function، حذف المفتاح المضمّن، وإسقاط `user_type/phone` من استدعاءات `profiles` أو إضافتها للمخطط رسمياً.
7. **تصحيح الاستعلامات المباشرة** (C-12/13/14): أعمدة `business_members` الفعلية، وإعادة تصميم تضمينات النزاعات وفق FKs الحقيقية (أو views خلفية جاهزة للعرض).
8. **عدم ابتلاع الأخطاء**: إعادة `PostgrestException` برسائلها للواجهة بدل `false/null` الصامتة — نصف هذه الكسور كان سيظهر في أول اختبار حقيقي لو لم تُبتلع الأخطاء.
9. **إكمال المزامنة ثنائية الاتجاه** (H-4/5/6): سحب `ledger_entries` و`customer_currency_balances` وجدولة عبر `sync_checkpoints`، وتحديث `sync_status` بعد النجاح (M-6).
10. **ربط المرفقات بـ Storage** (C-15) عبر Edge Functions الموجودة بدل تمرير مسارات محلية.

---

*انتهى التقرير — أُعدّ بالقراءة المباشرة للملفات المذكورة، وكل مرجع سطر قابل للتحقق في المسارات المذكورة.*
