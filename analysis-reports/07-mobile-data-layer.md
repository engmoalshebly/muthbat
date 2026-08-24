# تقرير تدقيق طبقة البيانات في تطبيق الموبايل (Flutter)

**الدور:** مدقق_طبقة_البيانات_موبايل (Mobile Data Layer Auditor)
**التاريخ:** 2026-08-18
**النطاق:** الملفات الستة المحددة في المهمة + تحقق عابر للطبقات (cross-layer) مع تواقيع دوال RPC في `debt-ledger-supabase/supabase/migrations` للتحقق من صحة الاستدعاءات.

**الملفات المدققة:**
1. `mobile/lib/features/merchant/data/merchant_repository.dart` (472 سطراً)
2. `mobile/lib/core/sync/sync_engine.dart` (221 سطراً)
3. `mobile/lib/core/database/app_database.dart` (521 سطراً)
4. `mobile/lib/features/auth/presentation/controllers/auth_controller.dart` (527 سطراً)
5. `mobile/lib/core/config/supabase_config.dart` (50 سطراً)
6. `mobile/lib/core/services/whatsapp_otp_service.dart` (252 سطراً)

---

## أولاً: الخلاصة العامة

البنية المعمارية المعتمدة (كتابة تفاؤلية محلية + طابور أوامر + إرسال عبر RPC فقط) هي بنية صحيحة نظرياً وتتوافق مع مبدأ "كل التواصل عبر API". لكن التنفيذ الفعلي يحتوي على **كسر كامل في عقد الاتصال بين العميل والباكند**: أسماء الدوال والمعاملات المرسلة من العميل لا تطابق الدوال العامة المنشورة في migrations، ما يعني أن **غالبية العمليات المالية والإدارية ستفشل فعلياً عند أول اتصال حقيقي بالسيرفر**، بينما تستمر الواجهة في عرض أرصدة محلية محسوبة في العميل وكأنها موثقة. إضافة إلى ذلك، طبقة المصادقة تحتوي على مسارات التفاف كاملة تسمح بالدخول دون أي تحقق حقيقي من السيرفر.

---

## ثانياً: الملاحظات الحرجة [حرج]

### ح-1: عدم تطابق أسماء/معاملات RPC بين العميل والباكند — كل العمليات المالية المؤجلة ستفشل دائماً

محرك المزامنة يرسل الأوامر المعلقة بأسماء دوال ومعاملات لا تطابق الدوال العامة الموجودة فعلاً في الباكند:

| استدعاء العميل | الموقع | الدالة العامة الفعلية في الباكند | نتيجة الاستدعاء |
|---|---|---|---|
| `create_ledger_entry` بمعاملات `p_currency_code, p_category, p_payment_method, p_reference_number, p_bank_or_agent_name, p_attachment_path` | `sync_engine.dart:123` + بناء الـ payload في `merchant_repository.dart:129-143` | `public.create_ledger_entry` في `migrations/202607120002_functions_and_triggers.sql:413` **لا تقبل** أيّاً من هذه المعاملات الستة. الدالة التي تقبلها هي `public.command_create_ledger_entry` (`migrations/202608180012_multi_currency_and_categories.sql:114`) — لكنها **لا تقبل `p_attachment_path` أيضاً** | فشل دائم `PGRST202` (function not found) |
| `apply_customer_discount` بمعامل إضافي `p_currency_code` | `sync_engine.dart:125` + `merchant_repository.dart:190-196` | `public.apply_customer_discount` في `migrations/202608140010_double_entry_accounting.sql:404` تقبل فقط `(p_business_customer_id, p_amount, p_description, p_occurred_at, p_client_request_id)` — لا يوجد `p_currency_code` | فشل دائم `PGRST202` |
| `reverse_ledger_entry` بمعامل `p_original_entry_id` | `sync_engine.dart:127` + `merchant_repository.dart:259-263` | `public.reverse_ledger_entry` في `migrations/202607120002_functions_and_triggers.sql:453` تتوقع `p_entry_id` وليس `p_original_entry_id` | فشل دائم `PGRST202` |

**الأثر:** كل قيد دين/سداد/خصم/عكس يُنشأ أوفلاين (أو يفشل إرساله لحظياً) سيبقى في `offline_mutations_queue` إلى الأبد، يُعاد إرساله كل 30 ثانية (`sync_engine.dart:54`)، ويفشل في كل مرة. الواجهة في هذه الأثناء تعرض القيد والرصيد المحدَّث محلياً (`app_database.dart:365-475`) وكأن العملية ناجحة. النتيجة: **انحراف دائم وصامت بين أرصدة العميل المعروضة وبين قاعدة البيانات المركزية** — وهو أسوأ سيناريو ممكن لمنتج مالي. الخطأ يُسجَّل فقط في `debugPrint` (`sync_engine.dart:137`) ولا يصل للمستخدم.

### ح-2: أربع عمليات كاملة تستدعي دوال غير موجودة إطلاقاً في الـ schema العام

في `merchant_repository.dart`:

- **سطر 349:** `client.rpc('command_add_dispute_message', ...)` — الدالة العامة الفعلية هي `public.add_dispute_message` (`migrations/202607120002_functions_and_triggers.sql:563`). الاسم `command_add_dispute_message` موجود فقط في schema `private` غير المعرَّض عبر PostgREST.
- **سطر 367:** `client.rpc('command_resolve_dispute', ...)` — الدالة العامة هي `public.resolve_dispute` (`...002_functions_and_triggers.sql:606`)، ومعامل الملاحظة فيها `p_resolution_note` بينما العميل يرسل `p_note` (سطر 371) — خطأ مزدوج (اسم + معامل).
- **سطر 422:** `client.rpc('command_invite_business_member', ...)` — الدالة العامة هي `public.invite_business_member` (`migrations/202608140008_member_invites_and_statement_commands.sql:60`) وتتوقع `p_target_user_id` (uuid) بينما العميل يرسل `p_phone` (سطر 424) — خطأ مزدوج.
- **سطر 452:** `client.rpc('command_generate_statement', ...)` — لا توجد أي دالة بهذا الاسم؛ الدالة العامة هي `public.create_statement` (`migrations/202608140008_member_invites_and_statement_commands.sql:185`).

**الأثر:** ميزات النزاعات (إرسال رسالة، حل نزاع)، دعوات فريق العمل، وتوليد كشوفات الحساب الموقعة **معطلة بالكامل** في البيئة الحقيقية. والأسوأ أن كل هذه الدوال تبتلع الاستثناء وتعيد `false`/`null` بصمت (أسطر 354-356، 374-376، 428-430، 468-470) دون أي رسالة خطأ حقيقية للمستخدم أو سجل.

### ح-3: التحقق من OTP يتم بالكامل في العميل مع أكواد التفاف ثابتة

- `whatsapp_otp_service.dart:196-199`: الكودان الثابتان `'123456'` و`'000000'` يُقبلان دائماً كرمز تحقق صالح (`valid: true`) دون أي اتصال بالسيرفر.
- `auth_controller.dart:397`: حتى لو فشل التحقق عبر الخدمة، يُقبل الدخول إذا كان الكود المدخل يساوي `state.mockOtpCode` — و`mockOtpCode` هو **رمز OTP الحقيقي نفسه المخزن في حالة التطبيق** (`auth_controller.dart:315-324` حيث `generatedCode = otpRes.otpCode` يُخزن في الحالة). أي أن رمز التحقق "السري" موجود في ذاكرة العميل ويُقارن في العميل — التحقق شكلي بالكامل وقابل للتجاوز بأي أداة تعديل ذاكرة أو إعادة بناء للتطبيق.
- الرمز الافتراضي `'123456'` معرَّف كقيمة افتراضية في `AuthState` نفسه (`auth_controller.dart:36`).

**الأثر:** إنشاء الحسابات وتسجيل الدخول عبر OTP غير آمن إطلاقاً في صيغته الحالية؛ لا يصلح لأي إطلاق تجاري.

### ح-4: تسجيل دخول بدون أي تحقق من بيانات الاعتماد (Fallback محلي صامت)

`auth_controller.dart:128-138` (`loginWithPassword`): عند فشل `signInWithPassword` على Supabase — **لأي سبب** بما فيه كلمة سر خاطئة — ينتقل الكود إلى البحث في الكاش المحلي، وإن وُجد ملف شخصي مطابق للرقم يُعتبر المستخدم **موثقاً** ويُحفظ في `SharedPreferences` وتُمنح له صلاحية `authenticated` كاملة. لا توجد أي مقارنة لكلمة السر في المسار المحلي.

وبالمثل `registerWithPassword` (`auth_controller.dart:238-289`): عند فشل `signUp` على السيرفر يُنشأ حساب محلي وهمي ويُسجَّل المستخدم كـ `authenticated` دون أن يعلم أن حسابه غير موجود على السيرفر.

**الأثر:** أي شخص يعرف رقم هاتف تاجر مسجَّل سابقاً على الجهاز يمكنه الدخول لحسابه. والحسابات "الوهمية" ستولّد بيانات محلية يتعذر مزامنتها لاحقاً.

### ح-5: استعادة الجلسة من SharedPreferences دون أي توكن أو تحقق

`auth_controller.dart:71-94` (`_checkExistingSession`): إذا وُجد `cached_user_id` في `SharedPreferences` يُعتبر المستخدم `authenticated` فوراً دون فحص `Supabase.auth.currentSession` أو صلاحية أي توكن. الجلسة المعتمدة هي مجرد نصوص plain في SharedPreferences (`cached_user_id`, `cached_user_type`، أسطر 176-180) يمكن تعديلها على أي جهاز rooted أو عبر نسخ الملفات.

**الأثر:** انتحال الهوية محلياً trivial؛ والأسوأ أن `user_type` (تاجر/عميل) يُقرأ من نفس المصدر القابل للتعديل.

### ح-6: مفاتيح API وأسرار مضمَّنة في كود العميل

- `whatsapp_otp_service.dart:28-29`: `sessionId` و`apiKey` لبوابة OpenWA Enterprise مكتوبان نصياً في الكود المصدري وبالتالي في الحزمة المُصدَرة (APK/IPA) — قابلان للاستخراج وإساءة الاستخدام (إرسال رسائل واتساب باسم المنصة).
- `whatsapp_otp_service.dart:32-36`: عناوين السيرفر هي عناوين شبكة محلية للتطوير (`192.168.0.134`، `localhost`، `10.0.2.2`) — بقايا بيئة تطوير غير صالحة للإنتاج.
- `supabase_config.dart:8-13`: العنوان الافتراضي `127.0.0.1:55321` ومفتاح anon محلي افتراضي — لا يوجد أي إعداد إنتاج. كما أن عنوان Supabase ومفتاحه قابلان للتعديل من المستخدم عبر SharedPreferences (`supabase_config.dart:36-49`) دون أي تحقق.

---

## ثالثاً: الملاحظات العالية [عالي]

### ع-1: حساب الأرصدة في العميل + تجاهل نوع القيد `reversal`

`app_database.dart:405-411` (`saveLedgerEntryOptimistic`): الرصيد المحلي يُحدَّث بجمع/طرح المبلغ حسب `entry_type`، لكن المنطق يعالج فقط `debt/fee/payment/discount`. قيود العكس (`reversal`) التي يولّدها `merchant_repository.dart:224-274` **لا تطابق أي فرع**، فتُحفظ القيد محلياً لكن **الرصيد لا يُعدَّل** — رصيد محلي خاطئ فوراً بعد أي عملية عكس.

إضافة إلى ذلك، مبدأ حساب الرصيد في العميل أصلاً (أسطر 393-460) يكرر منطق الباكند ويمكن التلاعب به محلياً؛ الرصيد المعروض للتاجر هو رصيد محلي قابل للتعديل على الجهاز وليس رصيداً موثقاً من السيرفر.

### ع-2: إضافة عميل جديد لا تُدرج أي أمر في طابور المزامنة — العميل لا يصل للسيرفر أبداً

`merchant_repository.dart:46-81` (`addCustomer`): يحفظ العميل محلياً بـ `syncStatus: 'pending'` ثم يستدعي `triggerSync()`، لكن **لا يوجد أي إدراج في `offline_mutations_queue`** ولا يوجد `command_type` لإنشاء عميل في `sync_engine.dart:122-132`. النتيجة:

1. العميل الجديد يبقى محلياً فقط إلى الأبد.
2. أي قيد مالي يُنشأ لهذا العميل سيحمل `p_business_customer_id = 'cust-<uuid محلي>'` غير موجود على السيرفر → فشل FK حتى لو صُحّحت أسماء الدوال.

### ع-3: سحب البيانات (Pull) لا يجلب القيود المالية إطلاقاً + كتابة فوقية بلا حل تعارضات

`sync_engine.dart:147-220` (`_pullRemoteUpdates`): يسحب المحلات والعملاء والأرصدة فقط. **لا يوجد أي سحب لجدول `ledger_entries` أو النزاعات أو الكشوفات** — القيود المُنشأة من أجهزة أخرى أو من الباكند لن تظهر أبداً في الكاش المحلي. والسحب يكتب فوق السجلات المحلية بـ `ConflictAlgorithm.replace` (`app_database.dart:303-310`) دون أي فحص `updated_at` أو حماية للسجلات ذات `sync_status = 'pending*'` — لا توجد استراتيجية حل تعارضات من أي نوع.

كذلك `sync_engine.dart:187-213`: الرصيد المسحوب من view `business_customer_balances` هو قيمة مسطحة واحدة تكتب فوق `current_balance` المحلي، بينما جدول `local_customer_currency_balances` (متعدد العملات) **لا يُحدَّث من السيرفر أبداً** — بعد أول مزامنة ناجحة، الأرصدة متعددة العملات المعروضة تصبح قديمة/منحرفة بشكل دائم.

### ع-4: كتابة مباشرة على جدول `profiles` من العميل (خرق لمبدأ API-only)

`auth_controller.dart:230` و`auth_controller.dart:416`: `Supabase.instance.client.from('profiles').upsert({...})` — كتابة مباشرة على جدول عام من العميل، تتجاوز أي منطق باكند (validation/triggers) وتعتمد كلياً على RLS. هذا هو النمط الوحيد للكتابة المباشرة، لكنه يخالف قاعدة المشروع المعلنة "كل التواصل عبر API فقط". (ملاحظة: فحص شامل لكل `mobile/lib` أكد أن هذين السطرين هما الوحيدان من نوع `insert/update/delete/upsert` على جداول Supabase — بقية الكتابات تمر عبر RPC.)

### ع-5: حذف طابور العمليات غير المرسلة عند تسجيل الخروج — فقدان بيانات مالية

`auth_controller.dart:505` يستدعي `AppDatabase.instance.clearAll()` عند `signOut`، و`app_database.dart:511-520` يحذف `offline_mutations_queue` ضمن الجداول. أي قيود مالية أُنشئت أوفلاين ولم تُزامَن بعد **تُحذف نهائياً بصمت** عند تسجيل الخروج — فقدان بيانات مالية غير قابل للاسترجاع دون تحذير المستخدم.

### ع-6: لا حد أقصى لإعادة المحاولة ولا Dead-Letter للعمليات الفاشلة

`app_database.dart:496-503` (`updateMutationAttempt`) يزيد `attempt_count` فقط، ولا يوجد أي شرط في `sync_engine.dart:116-143` يوقف إعادة المحاولة بعد N محاولات أو يعزل العملية المعطوبة. مع الخلل ح-1، كل عملية فاشلة فشلاً دائماً (خطأ مخطط وليس شبكة) ستُعاد كل 30 ثانية للأبد، وتُغرق السجلات، وتُبقي عداد "عمليات معلقة" مضللاً للمستخدم. لا يوجد أيضاً backoff تصاعدي ولا تمييز بين أخطاء الشبكة المؤقتة وأخطاء 4xx الدائمة.

### ع-7: `occurred_at` يُؤخذ من ساعة الجهاز ويُرسل للسيرفر

`merchant_repository.dart:101, 141` و`168` و`236`: `DateTime.now()` من جهاز العميل تُرسل كـ `p_occurred_at`، والباكند يقبلها. ساعة الجهاز قابلة للتعديل → إمكانية تأخير/تقديم تواريخ القيود المالية (تلاعب بتواريخ الاستحقاق والكشوفات). الأصح أن يفرض السيرفر `now()` أو يتحقق من انحراف معقول.

### ع-8: التخزين المحلي غير مشفر ويحوي بيانات مالية وشخصية

- `app_database.dart:11`: قاعدة SQLite عادية (`muthbat_offline_ledger.db`) بلا تشفير (لا SQLCipher) — تحوي قيوداً مالية وأرقام هواتف وأرصدة عملاء.
- `supabase_config.dart:45-48`: عنوان ومفتاح Supabase يُحفظان نصياً في SharedPreferences.
- `auth_controller.dart:22, 56`: `pendingPassword` (كلمة سر المستخدم أثناء التسجيل) تُحفظ في حالة التطبيق في الذاكرة كنص صريح حتى اكتمال OTP.

### ع-9: معرّفات محلية مؤقتة لا تُسوَّى مع معرّفات السيرفر

القيود المحلية تُنشأ بمعرّف `'entry-<uuid>'` (`merchant_repository.dart:100`) والعملاء بـ `'cust-<uuid>'` (سطر 54) والمحلات بـ `'biz-<resolvedUserId>'` (`auth_controller.dart:155`). بعد نجاح الإدراج على السيرفر (بمعرّف مختلف يولّده السيرفر) لا توجد أي خطوة reconciliation تربط السجل المحلي بمعرّف السيرفر أو تحدّث `sync_status` من `pending_insert` إلى `synced`. عمليات العكس اللاحقة سترسل `p_original_entry_id` يشير لمعرّف محلي لا يعرفه السيرفر.

---

## رابعاً: الملاحظات المتوسطة [متوسط]

### م-1: استعلامات N+1 في سحب الأرصدة
`sync_engine.dart:185-213`: لكل عميل يُنفَّذ استعلام منفصل على view `business_customer_balances`. مع مئات العملاء تصبح المزامنة الدورية (كل 30 ثانية) عبئاً على الشبكة والبطارية. الأصح استعلام واحد بـ `in_` filter.

### م-2: عملة قيد العكس الافتراضية خاطئة
`merchant_repository.dart:232`: `reverseLedgerEntry` يفترض `currencyCode = 'YER'` بدل قراءة عملة القيد الأصلي — في بيئة تعدد عملات، القيد التفاؤلي المعروض محلياً سيظهر بعملة خاطئة (السيرفر يشتق العملة من القيد الأصلي، فيحدث تعارض عرض محلي/سيرفر).

### م-3: ابتلاع الأخطاء وإرجاع بيانات قديمة كأنها حية
`merchant_repository.dart:316-325` (`getDisputes`): عند فشل الشبكة يُرجع الكاش المحلي بصمت دون مؤشر "بيانات قديمة". و`getMembers`/`getMemberInvites` (أسطر 394-396، 409-411) تُرجع قائمة فارغة عند أي خطأ — لا يمكن تمييز "لا يوجد أعضاء" من "فشل الاتصال".

### م-4: ازدواجية مصادر OTP ومخاطر تضارب
`auth_controller.dart:355-360` (`sendOtp`): يرسل OTP عبر OpenWA **و** يستدعي `Supabase.auth.signInWithOtp` في نفس الوقت — مساران مستقلان لرمزين مختلفين محتملين لنفس الرقم، دون توضيح أيّهما المعتمد. كما أن `verifyOtp` لا يستدعي `Supabase.auth.verifyOTP` إطلاقاً — مسار Supabase OTP ميت عملياً.

### م-5: وضع `offlineMockMode` قابل للتفعيل من المستخدم
`supabase_config.dart:17, 29, 39-48`: flag `offline_mock_mode` يُقرأ من SharedPreferences ويمكن للمستخدم تفعيله، فيتوقف الإرسال للسيرفر كلياً (`sync_engine.dart:109, 148`) مع استمرار التطبيق في تسجيل قيود مالية محلياً — وضع خطر إن وصل لنسخة الإنتاج.

### م-6: مسارات أوامر ميتة/يتيمة في محرك المزامنة
`sync_engine.dart:128-131` يعالج `confirm_ledger_entry` و`open_dispute`، لكن لا يوجد في الملفات المدققة أي موضع يُدرج هذين النوعين في الطابور. إما أن الكود المنتج لهما مفقود، أو أن هناك مسارات غير مكتملة — يحتاج تأكيداً من بقية features.

### م-7: ترحيل مخطط SQLite هش
`app_database.dart:58-72`: أعمدة تُضاف بـ `ALTER TABLE ... try/catch {}` صامتة، و`_dbVersion = 2` بلا `onUpgrade` — أي فشل ترحيل يُبتلع، ولا يوجد مسار ترقية منهجي للإصدارات القادمة.

---

## خامساً: الملاحظات المنخفضة [منخفض]

- **خ-1:** `merchant_repository.dart:460-464`: بعد `command_generate_statement` (المعطلة أصلاً، ح-2) يُجلب الكشف بـ `.from('statements').select()` — قراءة مباشرة مقبولة مبدئياً لكنها تكشف بيانات الكشف خارج مسار API موحّد.
- **خ-2:** `sync_engine.dart:54`: المزامنة الدورية كل 30 ثانية بلا فحص حالة البطارية/الشبكة المترية — استهلاك زائد.
- **خ-3:** `whatsapp_otp_service.dart:38-41`: حالة OTP (`_activeOtps`) في الذاكرة فقط — إعادة تشغيل التطبيق تفقد الرموز المرسلة، والمستخدم مضطر لطلب رمز جديد (تجربة استخدام).
- **خ-4:** `auth_controller.dart:104`: توليد `resolvedUserId` من رقم الهاتف (`usr-<digits>`) كنمط fallback يجعل معرّفات المستخدمين قابلة للتخمين والتصادم.
- **خ-5:** رسائل الأخطاء للمستخدم عامة دائماً (`auth_controller.dart:198, 294, 331, 374, 487`) ولا تميز بين خطأ شبكة وخطأ بيانات — يصعّب الدعم الفني.

---

## سادساً: النقاط الإيجابية [إيجابي]

- **إ-1:** مبدأ API-only مطبَّق فعلياً على كل العمليات المالية: لا يوجد أي `insert/update/delete` مباشر من العميل على جداول `ledger_entries` أو `business_customers` أو `disputes` — كل الكتابات المالية تمر عبر RPC (تأكد بفحص شامل لكل `mobile/lib`؛ الاستثناء الوحيد `profiles.upsert` — ع-4).
- **إ-2:** تصميم idempotency سليم: `client_request_id` (UUID) يولَّد في العميل (`merchant_repository.dart:99`) ويقابله قيد فريد في الباكند `unique(business_id, client_request_id)` (`migrations/202607120001_core_schema.sql:176`) مع فحص مسبق داخل دوال الأوامر — إعادة الإرسال بعد نجاح سيرفر مع فقدان الاستجابة آمنة نظرياً.
- **إ-3:** الحفظ التفاؤلي + إدراج الطابور يتمان داخل **معاملة SQLite واحدة** (`app_database.dart:371-474`) — لا يمكن أن يظهر قيد محلياً دون أن يدخل الطابور.
- **إ-4:** حارس التزامن `_isProcessing` (`sync_engine.dart:39, 78-79`) يمنع تداخل جولات المزامنة، والطابور يُعالج بترتيب FIFO (`app_database.dart:483`).
- **إ-5:** محاولات حسن نية في خدمة OTP: `Random.secure()` للتوليد (`whatsapp_otp_service.dart:96`)، صلاحية 5 دقائق، 5 محاولات، حارس طلبات متزامنة، وفترة انتظار 60 ثانية — وإن كانت كلها ضمانات طرف-عميل قابلة للتجاوز ويجب نقلها للسيرفر.
- **إ-6:** فصل واضح للمسؤوليات: Repository (منطق) / AppDatabase (تخزين) / SyncEngine (نقل) — بنية قابلة للصيانة والاختبار.

---

## سابعاً: توصيات الإصلاح ذات الأولوية (قبل الإطلاق التجاري)

1. **توحيد عقد RPC فوراً:** إما إعادة تسمية استدعاءات العميل لتطابق الدوال العامة (`create_ledger_entry` → إضافة المعاملات الناقصة للدالة العامة أو استدعاء `command_create_ledger_entry` بدون `p_attachment_path`)، وتصحيح `p_original_entry_id` → `p_entry_id`، وإزالة `p_currency_code` من `apply_customer_discount` أو إضافته للدالة، واستبدال `command_add_dispute_message/resolve_dispute/invite_business_member/generate_statement` بالأسماء العامة الصحيحة (`add_dispute_message`, `resolve_dispute` مع `p_resolution_note`, `invite_business_member` مع `p_target_user_id`, `create_statement`). ثم اختبار تكامل end-to-end إلزامي لكل أمر.
2. **إيقاف ابتلاع الأخطاء:** إظهار فشل العمليات للمستخدم وتمييز أخطاء 4xx الدائمة (إخراجها من الطابور لحالة "فشل نهائي") عن أخطاء الشبكة المؤقتة، مع حد أقصى للمحاولات وbackoff.
3. **إزالة كل مسارات الالتفاف في المصادقة:** حذف أنماط `'123456'/'000000'`، وحذف قبول `mockOtpCode`، ونقل توليد/تحقق OTP للسيرفر (Edge Function)، ومنع الدخول دون جلسة Supabase صالحة، وحذف fallback المحلي في `loginWithPassword`.
4. **إخراج الأسرار من العميل:** مفتاح OpenWA يجب أن يعيش في Edge Function، وإعداد عنوان Supabase للإنتاج عبر build-time config لا SharedPreferences.
5. **إكمال دورة المزامنة:** إدراج أمر إنشاء العميل في الطابور، سحب `ledger_entries` من السيرفر، تحديث `local_customer_currency_balances` من السيرفر، وتسوية المعرّفات المحلية بمعرّفات السيرفر بعد نجاح الإدراج.
6. **حماية البيانات المحلية:** تشفير SQLite (SQLCipher)، ومنع حذف الطابور عند signOut قبل اكتمال المزامنة (أو تحذير صريح)، واعتماد `now()` من السيرفر لتواريخ القيود.
7. **إصلاح منطق الرصيد المحلي:** معالجة `reversal` في `saveLedgerEntryOptimistic`، وجعل الرصيد المعروض "قراءة من السيرفر + تعديل تفاؤلي موسوم" لا مصدرَ حقيقة.

---

*انتهى التقرير — مدقق_طبقة_البيانات_موبايل*
