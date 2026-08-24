# خطة ربط الميزات المعطلة من الطرف إلى الطرف (Broken Features Wiring Plan)

**المخطط:** مخطط_ربط_الميزات_المعطلة
**النطاق:** `mobile/lib/features/` (النزاعات، الفريق، الكشوفات، شاشة العميل) ↔ `debt-ledger-supabase/supabase/functions/` + عقود RPC
**المرجع الأساسي:** `analysis-reports/08-api-contracts.md` (الملاحظات C-1…C-15، H-1…H-7، M-1…M-7)
**قاعدة العمل:** كل خطوة تشير إلى ملف/سطر حقيقي تمت قراءته. لا تعديل على أي ملف مشروع ضمن هذه الخطة.

---

## 0. ملخص تنفيذي

التشخيص الجذري واحد ومتكرر: **الواجهة تتحدث لغة والباكند يتحدث لغة أخرى، وبلوكات `try/catch` تبتلع أخطاء الترجمة**. الباكند سليم البنية (أوامر عبر RPC + قراءة عبر RLS + Edge Functions جاهزة)، لذلك فلسفة هذه الخطة هي: **تصحيح العميل ليتكلم لغة الباكند، لا العكس**، مع ثلاثة استثناءات مدروسة حيث الباكند نفسه ناقص (تعدد العملات، دليل الموظفين بالهاتف، أسماء أعضاء الفريق).

**النتيجة المستهدفة:** 19 عملية معطلة/وهمية في مصفوفة التقرير (قسم 9) تتحول إلى «موصولة ومقبولة اختبارياً»، موزعة على 4 أسابيع: أسبوع صفر للكسر الحرج، أسبوعان للربط الكامل، أسبوع للتصليب والقبول.

**مبدأ الترتيب الحاكم:** العقد أولاً، ثم القراءة، ثم الكتابة، ثم الأثقال (PDF/مرفقات). أي ميزة لا يمكن اختبارها End-to-End لا تُغلق.

---

## 1. القرارات المعمارية المحسومة

### D1 — تصحيح أسماء RPC في العميل، لا wrappers في الباكند
- **الخيارات:** (أ) تصحيح `merchant_repository.dart` ليستدعي `add_dispute_message / resolve_dispute / invite_business_member / create_statement`؛ (ب) إضافة دوال عامة جديدة بالأسماء `command_*` التي تتوقعها الواجهة.
- **التوصية: (أ).** الأسماء العامة الحالية هي العقد الموثق في `0002:563,606` و`0008:60,185`، ومنحها موجودة (`0003:56-65`). إضافة wrappers تضاعف سطح API بلا مبرر وتخلق ازدواجية صيانتها أخطر من تعديل 4 أسطر في العميل.

### D2 — عقد `create_ledger_entry`: مساران متسلسلان (جسر مؤقت ثم عقد نهائي)
- **الخيارات:** (أ) إجبار العميل فوراً على توقيع الـ 9 معاملات الحالي (`0002:413`) وحذف حقول العملة/التصنيف/السداد من الواجهة؛ (ب) انتظار إصلاح migration 12 (`202608180012`) ثم اعتماد التوقيع الموسع دفعة واحدة؛ (ج) مساران: جسر مؤقت بالتوقيع الحالي + هجرة لتوقيع موسع موحد.
- **التوصية: (ج).** المرحلة صفر تحتاج فتح المزامنة فوراً دون انتظار مخطط الباكند: العميل يرسل المعاملات التسعة فقط ويحتفظ بالحقول الإضافية محلياً. بالتوازي، مخطط الباكند يصحح migration 12 (تعريف `has_business_permission`، تصحيح `direction` إلى `debit/credit`، إسقاط `fee`) ويعيد تسمية الدالة إلى `public.create_ledger_entry` بتوقيع موسع واحد **بمعاملات افتراضية** (تجنباً لغموض overloading في PostgREST)، ثم يهاجر العميل إليه في المرحلة 1. ملاحظة: `p_attachment_path` يُسقط نهائياً من الحمولة — المرفقات تسلك مسار الملفات (قسم 5، D5) وليس عموداً في القيد.

### D3 — تعدد العملات: قفل الواجهة على عملة المحل في MVP
- **الخيارات:** (أ) تفعيل YER/SAR/USD كاملاً الآن؛ (ب) قفل منتقي العملة في `create_ledger_entry_sheet.dart:90` و`customer_ledger_screen.dart:33-37` على `businesses.currency_code` حتى إصلاح الباكند.
- **التوصية: (ب).** القيد الخلفي `0010:329-330` يرفض أي عملة مخالفة، و`customer_currency_balances` غير موجود فعلياً (C-6). شحن منتقي عملات يفشل عند الإرسال أسوأ منتجياً من قفله. تعدد العملات الكامل = مرحلة 2 بعد اكتمال إصلاح migration 12 وقرار المنتج.

### D4 — إضافة العميل عبر Edge Function `customer-directory` لا عبر RPC مباشر
- **الخيارات:** (أ) استدعاء `add_business_customer` مباشرة من العميل؛ (ب) استدعاء `customer-directory`.
- **التوصية: (ب).** الدالة (`functions/customer-directory/index.ts`) تحل في استدعاء واحد كل سلسلة الكسر C-5: تطبيع E164، البحث بـ `phone_hash`، إنشاء سجل `customers` إن غاب، تشفير الهاتف في `private.customer_contacts`، استدعاء `add_business_customer` بجلسة المستخدم، وإطلاق `request_customer_link` اختيارياً — مع rate-limiting وتحقق من الدور. استدعاء RPC مباشر كان سيفشل أصلاً لأن العميل لا يملك `customer_id` (C-5).

### D5 — المرفقات: خط أنابيب «بعد المزامنة» وليس معامل إنشاء
- **الخيارات:** (أ) رفع المرفق قبل إنشاء القيد؛ (ب) رفعه بعد نجاح مزامنة القيد ومعرفة `entry_id` الخادمي.
- **التوصية: (ب).** `signed-document-upload` يشترط `entityId` لقيد موجود خلفياً (`canAccessEntity`)، والقيد أوفلاين-أول لا يملك معرفاً خادمياً عند الإنشاء. التصميم: الملف يُحفظ محلياً مع `client_request_id`، وبعد نجاح الدفع (push) يجلب محرك المزامنة المعرف الخادمي ويُشغّل عامل مرفقات: `signed-document-upload` → `storage.uploadToSignedUrl` → `finalize-document-upload`.

### D6 — دعوة الموظفين: جسر UUID مؤقت ثم دليل هاتفي
- **الخيارات:** (أ) إبقاء إدخال User ID يدوياً؛ (ب) Edge Function جديدة `member-directory` تبحث بالهاتف (نمط `customer-directory`)؛ (ج) تعديل `invite_business_member` ليقبل هاتفاً.
- **التوصية: (ب) كهدف نهائي، مع جسر (أ) مصحح في المرحلة صفر.** الدعوة بالهاتف تتطلب بحثاً بـ hash عبر `private.customer_contacts`/جدول جهات اتصال المستخدمين — وهذا توسيع باكند (ملك مخطط الباكند). إلى أن يصل، نصحح الخلط المفاهيمي الحالي: `invite_member_sheet.dart:117` يطلب User ID فعلاً، لكن `merchant_repository.dart:424` يرسله في `p_phone` — الجسر يجعل الميزة تعمل بالمعرّف للتجريبي المغلق.

### D7 — عرض PDF الكشف: فتح خارجي عبر `url_launcher`، لا عارض مدمج
- **الخيارات:** (أ) حزمة عرض PDF داخلية؛ (ب) فتح `signedUrl` خارجياً.
- **التوصية: (ب).** `statement_preview_screen.dart:223-228` يحتوي المسار كاملاً جاهزاً (`Uri.parse` + إخفاء الزر عند `null`) — المطلوب فقط تغذية `downloadUrl` من استجابة `generate-statement` (`signedUrl`، صلاحية 3600 ثانية). لا حزم جديدة في MVP. إعادة توليد الرابط عند انتهائه = إعادة استدعاء الدالة بـ `statementId` (الدالة تدعم التمرير المباشر، `index.ts:425-443`).

### D8 — أسماء أعضاء الفريق والنزاعات: View خلفية، لا التفافات عميل
- **الخيارات:** (أ) استعلامات متعددة ودمج في Dart؛ (ب) View بـ `security definer` يكشف `display_name` للأعضاء.
- **التوصية: (ب) لشاشة الفريق، و(أ) مؤقتاً للنزاعات.** سياسة `profiles_select_own` (`0003:95`) تمنع قراءة ملفات الآخرين، فلا حل عميلياً نقياً لأسماء الأعضاء — View خلفية `business_member_directory` (اعتمادية على مخطط الباكند). للنزاعات، التضمين المتداخل `ledger_entries(business_customers(local_display_name))` يعمل عميلياً فوراً لأن FKs موجودة (`0001:218→161→125`).

---

## 2. مصفوفة «ميزة ↔ شاشة ↔ API» النهائية

| # | الميزة | الشاشة/الملف | القناة النهائية | يُبنى أولاً | التصنيف |
|---|---|---|---|---|---|
| F1 | رسالة نزاع | `dispute_detail_screen.dart` → `merchant_repository.dart:346-357` | RPC `add_dispute_message(p_dispute_id, p_message)` | عميل فقط (الباكند جاهز) | [فوري] |
| F2 | حل نزاع | `resolve_dispute_sheet.dart:47` → `merchant_repository.dart:359-377` | RPC `resolve_dispute(p_dispute_id, p_resolution, p_resolution_note, p_corrected_amount)` | عميل فقط | [فوري] |
| F3 | قائمة النزاعات | `disputes_list_screen.dart` → `merchant_repository.dart:279-326` | SELECT `disputes` + تضمين متداخل مصحح | عميل فقط | [فوري] |
| F4 | محادثة النزاع | `dispute_detail_screen.dart:46-57` → `:328-344` | SELECT `dispute_messages` (أعمدة فعلية، بلا تضمين profiles) | عميل فقط | [فوري] |
| F5 | قائمة الفريق | `team_screen.dart:34` → `merchant_repository.dart:381-397` | SELECT `business_members` بأعمدة `role,status` + View أسماء | باكند (View) ثم عميل | [مرحلة صفر] |
| F6 | دعوة موظف | `invite_member_sheet.dart:38` → `:414-431` | RPC `invite_business_member(p_business_id, p_target_user_id, p_role)` ← لاحقاً `member-directory` | عميل (جسر) ثم باكند | [مرحلة صفر]→[مرحلة 1] |
| F7 | الرد على دعوة فريق | (غير موجودة — تُضاف في الإشعارات) | RPC `respond_business_member_invite(p_invite_id, p_accept)` | عميل فقط | [مرحلة 1] |
| F8 | توليد كشف (تاجر) | `generate_statement_sheet.dart:42` → `:445-471` | RPC `create_statement('business_customer', …)` ثم Edge `generate-statement` | عميل فقط | [فوري]+[مرحلة صفر] |
| F9 | عرض/مشاركة PDF | `statement_preview_screen.dart:223-258` | Edge `generate-statement` → `signedUrl` → `url_launcher` | عميل فقط | [مرحلة صفر] |
| F10 | التحقق برمز كشف | شاشة جديدة `verify_statement_screen.dart` | Edge `verify-statement` (GET عام، `?code=`) | عميل فقط | [مرحلة 1] |
| F11 | إضافة عميل | `add_customer_sheet.dart` → `merchant_repository.dart:46-81` | Edge `customer-directory` + طابور أوفلاين | عميل فقط (الدالة جاهزة) | [مرحلة صفر] |
| F12 | قيد دين/سداد | `create_ledger_entry_sheet.dart` → `:84-156` + `sync_engine.dart:122` | RPC `create_ledger_entry` (جسر 9 معاملات ← توقيع موسع) | عميل (جسر) ثم باكند | [فوري]→[مرحلة 1] |
| F13 | خصم | `discount_entry_sheet.dart` → `:159-207` | RPC `apply_customer_discount` (بلا `p_currency_code`) | عميل فقط | [فوري] |
| F14 | عكس قيد | `reversal_confirm_sheet.dart` → `:224-274` | RPC `reverse_ledger_entry(p_entry_id, …)` | عميل فقط | [فوري] |
| F15 | شاشة العميل (بيانات) | `customer_home_screen.dart` (كاملة) | `customer_business_summary` + `customer_link_requests` + `ledger_timeline` | عميل فقط (RLS جاهز) | [مرحلة صفر] |
| F16 | تأكيد قيد (عميل) | `customer_home_screen.dart:264-272` (زر وهمي) | RPC `confirm_ledger_entry` عبر طابور المزامنة | عميل فقط | [مرحلة صفر] |
| F17 | الرد على ربط (عميل) | بطاقة طلب الربط `:116-154` | RPC `respond_link_request(p_request_id, p_accept)` | عميل فقط | [مرحلة صفر] |
| F18 | فتح نزاع (عميل) | شاشة قيود العميل (تُضاف) | RPC `open_dispute` عبر الطابور + enum مصحح | عميل فقط | [مرحلة 1] |
| F19 | كشف مجمع (عميل) | `customer_home_screen.dart` (زر يُضاف) | RPC `create_statement('customer_consolidated', null, …)` + Edge `generate-statement` | عميل فقط | [مرحلة 1] |
| F20 | مرفقات القيود | `attachment_picker_widget.dart` | `signed-document-upload` → Storage → `finalize-document-upload` | عميل (عامل خلفية) | [مرحلة 1] |
| F21 | OTP واتساب | `whatsapp_otp_service.dart:28-36` | Edge `send-whatsapp-otp` بدل OpenWA المباشر | عميل (مع مخطط المصادقة) | [مرحلة صفر] |
| F22 | تشفير هاتف المستخدم | `auth_controller.dart` (بعد الدخول) | Edge `bootstrap-user-contact` | عميل (مع مخطط المصادقة) | [مرحلة 1] |

*(F23–F24: `process-notification-outbox` و`process-automation-rules` — تشغيل خادمي مجدول، لا ربط عميل؛ تُسند لمخطط الباكند/العمليات.)*

---

## 3. المرحلة صفر: إصلاحات العقود الفورية (الأسبوع 0)

### حزمة A — أسماء ومعاملات RPC الأربعة [فوري — خلال 24 ساعة]

**الخطوة 3.1 — رسائل النزاع (F1)**
- **الملف:** `mobile/lib/features/merchant/data/merchant_repository.dart:349`
- **التغيير:** `rpc('command_add_dispute_message', …)` → `rpc('add_dispute_message', …)`. المعاملات `p_dispute_id, p_message` مطابقة أصلاً (`0002:563`). إزالة `try/catch` المبتلع وإعادة رمي الخطأ (انظر الخطوة 3.9).
- **معيار التحقق:** إرسال رسالة من `dispute_detail_screen.dart` على نزاع حقيقي يُنشئ صفاً في `dispute_messages` ويحدّث `dispute_state.status` (قاعدة: `awaiting_merchant`/`awaiting_customer` حسب المرسل — `0002:563-586`).
- **الاعتماديات:** الخطوة 3.3 (قائمة نزاعات تعمل ليكون هناك نزاع حقيقي).
- **الجهد:** 0.25 يوم.

**الخطوة 3.2 — حل النزاع (F2)**
- **الملف:** `merchant_repository.dart:367-372`
- **التغيير:** الاسم → `resolve_dispute`؛ إعادة تسمية المعامل `'p_note'` → `'p_resolution_note'` (التوقيع في `0002:606`). قيم `_selectedResolution` في `resolve_dispute_sheet.dart:25` (`accepted/partially_accepted/rejected`) مطابقة للـ enum — لا تغيير.
- **معيار التحقق:** حل `partially_accepted` بمبلغ مصحح يُنشئ قيد عكس + قيد مصحح في `ledger_entries` ويغلق النزاع (`0002:606-618`).
- **الاعتماديات:** 3.3. **الجهد:** 0.25 يوم.

**الخطوة 3.3 — قائمة النزاعات: إصلاح التضمين (F3، C-13)**
- **الملف:** `merchant_repository.dart:294-302`
- **التغيير:** حذف `profiles!customer_id (display_name, phone)` (لا FK بهذا الاسم؛ `disputes.customer_id → customers(id)` في `0001:220`). الاستعلام الجديد:
  ```
  id, entry_id, business_id, customer_id, reason, description, created_at,
  dispute_state (status, resolution_note, resolved_at),
  ledger_entries (amount, currency_code, entry_type, description, occurred_at,
                   business_customers (local_display_name)),
  customers (global_code)
  ```
  (FKs: `disputes.entry_id → ledger_entries` `0001:218`؛ `ledger_entries.business_customer_id → business_customers` `0001:161`). تحديث `DisputeModel.fromMap` (`dispute_model.dart:38-60`) لقراءة `local_display_name` من المسار المتداخل و`global_code` بدل `phone` (الهاتف مشفر خلفياً ولا يُعرض).
- **معيار التحقق:** `disputes_list_screen.dart` يعرض نزاعات حقيقية بأسماء العملاء أونلاين؛ لا سقوط صامت إلى `local_disputes`.
- **الاعتماديات:** لا شيء. **الجهد:** 0.5 يوم.

**الخطوة 3.4 — محادثة النزاع (F4، C-14)**
- **الملف:** `merchant_repository.dart:331-338`
- **التغيير:** الاستعلام يطلب عموداً شبحاً `sender_id` — الفعلي `sender_user_id` (`0001:251`). الاستعلام الجديد: `id, dispute_id, sender_user_id, message, created_at` **بدون** تضمين `profiles` (لا FK + سياسة `profiles_select_own` تمنع قراءة الآخرين). تسمية المرسل تُشتق في العميل: `sender_user_id == currentUserId` → «أنت»؛ `== disputes.opened_by_user_id` → «العميل»؛ غير ذلك → «المحل».
- **معيار التحقق:** محادثة نزاع حقيقية تظهر مرتبة زمنياً مع تسميات مرسل صحيحة.
- **الاعتماديات:** 3.3. **الجهد:** 0.5 يوم.

**الخطوة 3.5 — قائمة الفريق (F5، C-12)**
- **الملف:** `merchant_repository.dart:385-391`
- **التغيير:** الأعمدة → `id, business_id, user_id, role, status, created_at` وحذف تضمين `profiles(display_name, phone)` (لا FK مباشر `business_members→profiles`، و`phone` غير موجود أصلاً في `profiles` — `0001:58-67`). `MemberModel.fromMap` (`member_model.dart:22-36`) جاهز لهذه الأعمدة فعلاً. العرض المؤقت: الدور المترجم (`roleLocalized`) + مقطع المعرّف، إلى أن يصل View الأسماء (اعتمادية B-1).
- **معيار التحقق:** `team_screen.dart` يعرض الأعضاء النشطين أونلاين بدل قائمة فارغة دائمة.
- **الاعتماديات:** لا شيء للإصلاح؛ عرض الأسماء يعتمد على B-1. **الجهد:** 0.25 يوم.

**الخطوة 3.6 — دعوة موظف: الجسر المصحح (F6، H-3)**
- **الملف:** `merchant_repository.dart:422-426`
- **التغيير:** الاسم → `invite_business_member`؛ المعاملات → `{'p_business_id', 'p_target_user_id': targetUserId, 'p_role': role}` (التوقيع `0008:60-64`). حذف مسار `p_phone`. إضافة تحقق صيغة UUID في `invite_member_sheet.dart:114-132` قبل الإرسال مع رسالة عربية واضحة.
- **معيار التحقق:** دعوة بمعرّف مستخدم حقيقي تُنشئ صفاً `pending` في `business_member_invites` وإشعاراً للهدف (`0008:55`).
- **الاعتماديات:** لا شيء. **الجهد:** 0.5 يوم.

**الخطوة 3.7 — توليد الكشف: الاسم والـ scope (F8، C-1/H-2)**
- **الملف:** `merchant_repository.dart:452-457`
- **التغيير:** الاسم → `create_statement`؛ `'p_scope': 'customer'` → `'business_customer'` (enum `statement_scope` في `0001:31`). بقية التدفق (قراءة `statements` بالمعرف الراجع `:460-464`) سليم.
- **معيار التحقق:** توليد كشف من `generate_statement_sheet.dart:42` يُنشئ `statements` + `statement_items` ويعرض المعاينة بأرقام حقيقية ورمز تحقق حقيقي.
- **الاعتماديات:** لا شيء. **الجهد:** 0.25 يوم.

**الخطوة 3.8 — حمولات طابور المزامنة (F12/F13/F14، C-2/C-3/C-4)**
- **الملفات:** `merchant_repository.dart:129-143` (إنشاء)، `:190-196` (خصم)، `:259-263` (عكس)
- **التغيير (جسر D2):**
  - إنشاء: حذف `p_currency_code, p_category, p_payment_method, p_reference_number, p_bank_or_agent_name, p_attachment_path` من الحمولة؛ إبقاء التسعة المطابقة لـ `0002:413-425` (مع `p_external_reference` و`p_source_device_id: null`). الحقول تبقى محفوظة محلياً في `local_ledger_entries`.
  - خصم: حذف `p_currency_code` (`0010:404-408` لا يقبله).
  - عكس: `p_original_entry_id` → `p_entry_id` (`0002:453`) — **مع شرط:** المعرف المرسل يجب أن يكون المعرف الخادمي؛ عكس قيد لم يُزامن بعد يُحظر في الواجهة (`reversal_confirm_sheet.dart`) برسالة «زامن القيد أولاً».
- **معيار التحقق:** إنشاء قيد أونلاين يُفرغ الطابور فعلياً (صف في `ledger_entries` بنفس `client_request_id`)؛ لا `PGRST202` في السجلات.
- **الاعتماديات:** لا شيء. **الجهد:** 0.5 يوم.

**الخطوة 3.9 — طبقة أخطاء موحدة (توصية 8 في التقرير) [فوري]**
- **الملفات:** جديد `mobile/lib/core/errors/api_exception.dart`؛ تعديل كل `catch` في `merchant_repository.dart` (الأسطر 316, 341, 354, 374, 394, 409, 428, 468)
- **التغيير:** تحويل `PostgrestException`/`FunctionException` إلى `ApiException` برسالة عربية مفهرسة بالكود: `PGRST202` → «عقد غير متطابق مع الخادم»، `42501` → «ليست لديك صلاحية»، `42703` → «بيانات غير متزامنة مع الخادم»، أخطاء منطق الأعمال (مثل `Payment exceeds current balance`) → رسالتها كما هي. الدوال تعيد `Result` أو ترمي — ممنوع `return false/null` الصامت. الواجهات تعرض الرسالة الفعلية بدل «تحقق من اتصالك».
- **معيار التحقق:** قطع الشبكة/خطأ صلاحية يعرض رسالة سبب حقيقية في كل شاشة معدّلة.
- **الاعتماديات:** لا شيء؛ تُدمج مع كل خطوة أعلاه. **الجهد:** 1 يوم.

**اعتماديات خارجية للمرحلة صفر (تُسلَّم لمخطط الباكند):**
- **B-1:** View `business_member_directory(business_id, user_id, role, status, display_name)` بـ `security definer` مقيد بعضوية المحل — لعرض أسماء الفريق (F5).
- **B-2:** إصلاح migration 12 + التوقيع الموسع الموحد لـ `create_ledger_entry` (D2) — للمرحلة 1.
- **B-3:** Edge Function `member-directory` للدعوة بالهاتف (D6) — للمرحلة 1.
- **B-4 (مع مخطط المصادقة):** إغلاق C-9/C-10/C-11 — بلاها تبقى كل الخطوات أعلاه قابلة للكسر بهويات وهمية.

---

## 4. خطة استبدال بيانات شاشة العميل الوهمية (F15–F19) [مرحلة صفر → مرحلة 1]

### 4.1 البنية الجديدة
- **ملف جديد:** `mobile/lib/features/customer/data/customer_repository.dart` + `customer_controller.dart` (Riverpod) + نماذج `customer_summary_model.dart`. شاشة العميل حالياً ملف واحد بلا طبقة بيانات إطلاقاً.
- **حل هوية العميل:** عند فتح الشاشة: `from('customers').select('id').eq('user_id', auth.uid()).maybeSingle()` (العمود `0001:71`؛ السياسة `customers_select_allowed` `0003:100`). غياب السجل = حالة «لا حساب عميل مرتبط» وليست خطأ.

### 4.2 الخطوات

**الخطوة 4.1 — الملخص المالي الحقيقي**
- **الملف:** `customer_home_screen.dart:88-105` (استبدال `'450,000 ر.ي'` و`'مرتبط بـ 2 محلات'`)
- **التغيير:** قراءة `from('customer_business_summary').select()` (العرض `0002:678-683`؛ `security_invoker` فتطبق RLS `business_customers_select_allowed` — العميل يرى صفوف `link_status='linked'` الخاصة به فقط، `0003:127-130`). الإجمالي = تجميع `current_balance` **مفصولة بالعملة** (`currency_code` في العرض) — ممنوع جمع عملات مختلفة في رقم واحد. عدد المحلات = `count`.
- **معيار التحقق:** عميل مرتبط بمحلين تجريبيين يرى مجموعاً يطابق `business_customer_balances`؛ عميل بلا روابط يرى صفراً وحالة فارغة.
- **الجهد:** 1 يوم. **الاعتماديات:** حل الهوية (4.1).

**الخطوة 4.2 — بطاقات المحلات الحقيقية**
- **الملف:** `customer_home_screen.dart:181-195` (البطاقتان الثابتتان) و`:159-174` (العدّاد)
- **التغيير:** توليد البطاقات من صفوف العرض نفسه: `business_name`، `business_type`، `current_balance`، `last_entry_at` (تنسيق نسبي)، `entry_count`. حذف `_buildBusinessCard` الثابت وتحويله ليقبل نموذجاً.
- **معيار التحقق:** قيد جديد من تاجر تجريبي يظهر أثره في البطاقة بعد تحديث/سحب.
- **الجهد:** 0.5 يوم. **الاعتماديات:** 4.1.

**الخطوة 4.3 — طلبات الربط الحقيقية + الرد (F17)**
- **الملف:** `customer_home_screen.dart:116-154` (البطاقة الوهمية)
- **التغيير:** قراءة `from('customer_link_requests').select('id, status, created_at, business_customers(local_display_name, businesses(name, city))').eq('target_customer_id', customerId).eq('status', 'pending')` (الجدول `0001:139-148`؛ السياسة `0003:136-143`؛ التضمين المتداخل ممكن عبر FKs `0001:141→125`). زرا «قبول/رفض» يستدعيان `rpc('respond_link_request', {p_request_id, p_accept})` (`0002:294`) ثم تحديث الحالة.
- **معيار التحقق:** تاجر يضيف عميلاً مسجلاً عبر `customer-directory` مع `requestLink=true` → يظهر الطلب للعميل → القبول يحوّل `link_status` إلى `linked` وتظهر بيانات المحل في 4.1/4.2.
- **الجهد:** 1 يوم. **الاعتماديات:** 4.1؛ F11 لإنشاء طلبات حقيقية.

**الخطوة 4.4 — تأكيد القيود الحقيقي (F16)**
- **الملف:** `customer_home_screen.dart:264-272` (الزر الوهمي) + `sync_engine.dart:128-129`
- **التغيير:** (1) جلب القيود المعلقة: `from('ledger_timeline').select().eq('confirmation_status', 'pending')` (العرض `0002:672-676`؛ enum `0001:21`) — زر «تأكيد السجل» يفتح قائمة القيود المعلقة بدل SnackBar فوري. (2) التأكيد يُدرج في الطابور عبر دالة جديدة `AppDatabase.enqueueMutation('confirm_ledger_entry', {p_entry_id, p_device_id: null})` — محرك المزامنة يعالج النوع أصلاً (`sync_engine.dart:128-129`) لكن لا أحد يُدرجه (H-6). (3) أونلاين: تنفيذ فوري ثم تحديث الكاش.
- **معيار التحقق:** تأكيد قيد يُنشئ صفاً في `entry_confirmations` ويحوّل الحالة إلى `confirmed` (`0002:496-498`)؛ يعمل أوفلاين ويُرسل عند عودة الشبكة.
- **الجهد:** 1.5 يوم. **الاعتماديات:** الخطوة 5.2 (دالة الإدراج العامة).

**الخطوة 4.5 — فتح نزاع من العميل (F18) [مرحلة 1]**
- **الملف:** شاشة جديدة `customer_entry_detail` (أو bottom sheet من قائمة القيود في 4.4)
- **التغيير:** استدعاء `open_dispute(p_entry_id, p_reason, p_description)` (`0002:530`) عبر الطابور (`sync_engine.dart:130-131` جاهز). **تصحيح أسباب النزاع (L-1):** خريطة ثابتة من قيم الواجهة إلى enum الباكند `('wrong_amount','unknown_transaction','duplicate','already_paid','wrong_date','wrong_description','other')` (`0001:24`) — قيم `dispute_model.dart:6` الحالية (`incorrect_amount`…) ممنوعة من الإرسال.
- **معيار التحقق:** نزاع يُفتح من جهاز العميل يظهر فوراً في `disputes_list_screen.dart` عند التاجر (بعد الخطوة 3.3) مع إشعار للمالك.
- **الجهد:** 1.5 يوم. **الاعتماديات:** 4.4، 3.3.

**الخطوة 4.6 — الكشف المجمع للعميل (F19) [مرحلة 1]**
- **الملف:** `customer_home_screen.dart` (زر «كشف حساب مجمع») + إعادة استخدام `statement_preview_screen.dart`
- **التغيير:** `rpc('create_statement', {p_scope: 'customer_consolidated', p_business_customer_id: null, p_period_from, p_period_to})` (`0008:185-190`) ثم Edge `generate-statement` بـ `{statementId}`، وعرض المعاينة بزر التحميل (D7).
- **معيار التحقق:** PDF مجمع يتضمن قيود كل المحلات المرتبطة برمز تحقق يجتاز F10.
- **الجهد:** 1 يوم. **الاعتماديات:** 5.4 (بوابة Edge)، F9.

---

## 5. خطة دمج Edge Functions في التطبيق (H-1)

### الخطوة 5.1 — بوابة موحدة `EdgeGateway` [مرحلة صفر]
- **الملف الجديد:** `mobile/lib/core/services/edge_gateway.dart`
- **التغيير:** غلاف typed فوق `Supabase.instance.client.functions.invoke` (يُرفق JWT تلقائياً من الجلسة — لا مصادقة يدوية). مواصفات موحدة: timeout 30 ثانية؛ تحويل `FunctionException` إلى `ApiException` (3.9) مع قراءة `error`/`code` من جسم الاستجابة (دوال `_shared/http.ts` ترجع `{error, message}`)؛ إعادة محاولة واحدة فقط لأخطاء الشبكة (ممنوع لـ 4xx).
- **معيار التحقق:** كل الاستدعاءات اللاحقة تمر عبره؛ انتهاء الجلسة يعطي 401 برسالة «سجّل الدخول مجدداً».
- **الجهد:** 0.5 يوم.

### الخطوة 5.2 — دالة إدراج عامة في الطابور [مرحلة صفر]
- **الملف:** `core/database/app_database.dart` (بعد `:463-473`)
- **التغيير:** استخراج `enqueueMutation({commandType, payload, localRefId})` من `saveLedgerEntryOptimistic` لتُستخدم لأوامر العميل (تأكيد/نزاع/رد ربط) وأوامر النزاع الأوفلاين. إضافة أنواع `respond_link_request` و`add_dispute_message` إلى معالج `sync_engine.dart:122-132`. سقف `attempt_count` = 10 ثم حالة `dead` تظهر للمستخدم (تخفيف H-5).
- **معيار التحقق:** تأكيد/نزاع أوفلاين يُرسل عند عودة الشبكة؛ أمر فاشل 10 مرات يظهر كـ«يحتاج مراجعة» ولا يعلق الطابور.
- **الجهد:** 1 يوم.

### الخطوة 5.3 — `send-whatsapp-otp` (F21) [مرحلة صفر — مع مخطط المصادقة]
- **الملف:** `core/services/whatsapp_otp_service.dart:28-36, 161-171`
- **التغيير:** حذف عنوان LAN (`192.168.0.134:2785`) والمفتاح المضمّن؛ الاستدعاء → `EdgeGateway.invoke('send-whatsapp-otp', {phone, otpCode})` (الدالة `functions/send-whatsapp-otp/index.ts` تقبل `{phone, otpCode, appName}`). توليد الرمز والتحقق الخلفي الكامل (إلغاء `123456/000000`، `auth_controller.dart:397`) = **اعتمادية B-4 على مخطط المصادقة** — خطتي تغطي قناة الإرسال فقط.
- **معيار التحقق:** رسالة واتساب تصل عبر الدالة؛ لا مفتاح API في حزمة التطبيق (`grep` نظيف).
- **الجهد:** 0.5 يوم.

### الخطوة 5.4 — `generate-statement` + عرض PDF (F8/F9) [مرحلة صفر]
- **الملفات:** `merchant_repository.dart:445-471`، `statement_preview_screen.dart:223-258`
- **التغيير:** بعد نجاح `create_statement` (3.7): `EdgeGateway.invoke('generate-statement', {statementId})` — الدالة تولّد PDF، تختم `snapshot_sha256_hex`، وترجع `{signedUrl, verificationCode, sha256Hex, …}` (`index.ts:534-549`). النتيجة → `StatementModel.copyWith(downloadUrl: signedUrl)` فيظهر زر التحميل المخفي حالياً (`:223`). زر المشاركة (`:242-249`) يضم رمز التحقق الحقيقي. انتهاء صلاحية الرابط (ساعة) → إعادة الاستدعاء بـ `statementId`.
- **معيار التحقق:** PDF يُفتح من الزر، ختم SHA-256 في `generate_statement_sheet.dart:128` يطابق `sha256Hex` الراجع، والرمز يجتاز `verify-statement`.
- **الجهد:** 1 يوم. **الاعتماديات:** 3.7، 5.1.

### الخطوة 5.5 — `verify-statement` (F10) [مرحلة 1]
- **الملف الجديد:** `features/merchant/presentation/screens/verify_statement_screen.dart` (+ مدخل من `merchant_profile_screen.dart` و`customer_home_screen.dart`)
- **التغيير:** الدالة عامة (GET، بلا `requireUser`، rate-limit بالـ IP) — تُستدعى بـ HTTP GET مباشر `…/functions/v1/verify-statement?code=XXX` مع ترويسة `apikey` (لا `functions.invoke` الافتراضي POST). حقل إدخال رمز + عرض نتيجة `{valid, periodFrom, periodTo, closingBalance, documentHash}` بصياغة عربية (صالح/غير صالح + بصمة المستند).
- **معيار التحقق:** رمز من كشف F9 يرجع `valid:true` ببيانات مطابقة؛ رمز مختلق يرجع `valid:false`؛ 31 محاولة/ساعة من IP واحد → 429 مع رسالة مفهومة.
- **الجهد:** 1 يوم. **الاعتماديات:** 5.4.

### الخطوة 5.6 — `customer-directory` لإضافة العميل (F11، C-5) [مرحلة صفر]
- **الملفات:** `merchant_repository.dart:46-81`، `add_customer_sheet.dart`
- **التغيير:** `addCustomer` يستدعي `EdgeGateway.invoke('customer-directory', {businessId, phone, localDisplayName, creditLimit, defaultDueDays, requestLink: true})`؛ الاستجابة `{businessCustomerId, linkRequestId, isRegistered, phoneLast4, globalCode}` تُخزن محلياً **بالمعرف الخادمي الحقيقي** بدل `'cust-${uuid}'` (`:54`). أوفلاين: يُحفظ محلياً بعلم `pending_directory` ويُدرج أمر في الطابور (نوع جديد في 5.2) — والقيود على عميل غير مُزامن تُحظر كما في 3.8. إلزامية حقل الهاتف في `add_customer_sheet.dart` (الدالة تشترطه) مع تطبيع صيغة يمنية `+967…`.
- **معيار التحقق:** عميل يُضاف أونلاين يظهر في `business_customers` خلفياً، وقيد عليه يُزامن بنجاح (سلسلة C-5 كاملة)؛ عميل مسجّل يستلم طلب ربط (4.3).
- **الجهد:** 1.5 يوم. **الاعتماديات:** 5.1، 5.2.

### الخطوة 5.7 — `bootstrap-user-contact` (F22) [مرحلة 1 — مع مخطط المصادقة]
- **الملف:** `features/auth/presentation/controllers/auth_controller.dart` (نقطة ما بعد الدخول الناجح)
- **التغيير:** بعد جلسة حقيقية: استعلام `customers` بالـ `user_id`؛ إن وُجد → `EdgeGateway.invoke('bootstrap-user-contact', {})` (بلا جسم — يقرأ هاتف الجلسة ويشفّره، `index.ts`)؛ خطأ `customer_not_found` يُتجاهل بهدوء (تاجر بلا حساب عميل). يُستدعى مرة واحدة ويُخزَّن علم محلي.
- **معيار التحقق:** `private.customer_contacts` يحوي hash/ciphertext للمستخدم → `service_find_customer_by_phone_hash` يجده → ربط العملاء بالهاتف يعمل.
- **الجهد:** 0.5 يوم. **الاعتماديات:** B-4 (جلسات حقيقية إلزامية).

### الخطوة 5.8 — خط أنابيب المرفقات (F20، C-15) [مرحلة 1]
- **الملفات:** `attachment_picker_widget.dart`، `create_ledger_entry_sheet.dart:84`، `sync_engine.dart`، ملف جديد `core/services/attachment_upload_worker.dart`
- **التغيير:** (1) المنتقي يحفظ الملف محلياً مربوطاً بـ `client_request_id` (لا `p_attachment_path` — أُسقط في 3.8). (2) محرك المزامنة بعد نجاح دفع قيد يجلب المعرف الخادمي: `from('ledger_entries').select('id').eq('client_request_id', …)` ويحدّث المحلي + `sync_status='synced'` (يحل M-6 أيضاً). (3) العامل: `signed-document-upload` `{entityType:'ledger_entry', entityId, filename, mimeType, sizeBytes, sha256Hex}` → `storage.uploadToSignedUrl(path, token, file)` → `finalize-document-upload` `{uploadSessionId}` → ربط تلقائي في `ledger_entry_files` (`finalize…/index.ts`). قيود: الأنواع الأربعة المسموحة و10MB (مفروضة خلفياً).
- **معيار التحقق:** صورة تُرفق بقيد أوفلاين تظهر في `files`/`ledger_entry_files` بعد المزامنة، وبصمتها تطابق المحلية.
- **الجهد:** 2 يوم. **الاعتماديات:** 3.8، 5.1، 5.2.

---

## 6. إصلاح الاستعلامات المباشرة المكسورة (خلاصة مرجعية)

| الاستعلام | الموقع | الكسر | الإصلاح | الخطوة |
|---|---|---|---|---|
| `getDisputes` | `merchant_repository.dart:294-302` | `profiles!customer_id` بلا FK (C-13) | تضمين متداخل عبر `ledger_entries→business_customers` + `customers(global_code)` | 3.3 |
| `getDisputeMessages` | `:331-338` | عمود `sender_id` شبح + تضمين `profiles` بلا FK (C-14) | `sender_user_id` بلا تضمين؛ تسمية مشتقة | 3.4 |
| `getMembers` | `:385-391` | أعمدة `member_role, permissions, is_active` غير موجودة (C-12) | `role, status` + View أسماء خلفي (B-1) | 3.5 |
| `getMemberInvites` | `:403-406` | سليم (T4) | إبقاء + إزالة ابتلاع الخطأ | 3.9 |
| `statements` | `:460-464` | سليم (T5) | إبقاء | 3.7 |
| سحب `business_customers` | `sync_engine.dart:179-183` | `phone` غير موجود خلفياً (M-2) | عرض `phoneLast4` من `customer-directory` محلياً فقط | 5.6 |
| سحب الأرصدة N+1 | `sync_engine.dart:185-191` | استعلام لكل عميل (M-5) | استعلام واحد `in('business_customer_id', ids)` | 7.2 |

---

## 7. ترتيب التنفيذ بالأسابيع ومعايير القبول

### الأسبوع 0 — «فتح الشرايين» [فوري + مرحلة صفر]
1. الخطوات 3.1–3.8 (حزمة A كاملة) — 2.5 يوم
2. الخطوة 3.9 (طبقة الأخطاء) — 1 يوم
3. الخطوة 5.1 + 5.2 (البوابة والطابور) — 1.5 يوم
4. الخطوة 5.6 (إضافة العميل) — 1.5 يوم
5. الخطوة 5.3 (قناة OTP) — 0.5 يوم *(بالتنسيق مع مخطط المصادقة)*

**معيار قبول الأسبوع:** سيناريو E2E على بيئة staging: تاجر يسجّل → يضيف عميلاً بهاتف → قيد دين يُزامن فعلياً (صف خلفي بنفس `client_request_id`) → عكس وخصم يُزامنان → لا `PGRST202/42703` في السجلات. **هذا المعيار يحظر الإطلاق.**

### الأسبوع 1 — «النزاعات والكشوفات» [مرحلة صفر]
1. الخطوات 3.3→3.1/3.2/3.4 (دورة النزاع كاملة عند التاجر) — 1.5 يوم
2. الخطوة 3.5 + 3.6 (الفريق والدعوات بالجسر) — 0.75 يوم
3. الخطوة 5.4 (PDF الكشف) — 1 يوم
4. الخطوة 7.2 أدناه (إصلاحات السحب) — 1 يوم

**معيار قبول الأسبوع:** نزاع كامل الحياة (فتح خلفي → رسائل متبادلة → حل `partially_accepted` بقيد مصحح) يعمل من الواجهة؛ كشف PDF بختم SHA-256 حقيقي يُفتح ويُشارك؛ شاشة الفريق تعرض الأعضاء.

### الأسبوع 2 — «تجربة العميل الحقيقية» [مرحلة صفر→1]
1. الخطوات 4.1–4.3 (بيانات + ربط) — 2.5 يوم
2. الخطوة 4.4 (التأكيد) — 1.5 يوم
3. الخطوة 4.5 (فتح نزاع عميل) — 1.5 يوم *(بداية مرحلة 1)*

**معيار قبول الأسبوع:** عميل حقيقي: يرى أرصدة صحيحة بعملاتها، يقبل ربطاً، يؤكد قيداً أوفلاين (يُرسل لاحقاً)، يفتح نزاعاً يظهر عند التاجر. صفر نص ثابت في `customer_home_screen.dart` (`grep '450,000'` = لا نتائج).

### الأسبوع 3 — «الإكمالات والتصليب» [مرحلة 1]
1. الخطوة 4.6 (كشف مجمع) + 5.5 (التحقق برمز) — 2 يوم
2. الخطوة 5.8 (المرفقات) — 2 يوم
3. الخطوة 5.7 (تشفير الهاتف) + F7 (الرد على دعوات الفريق من الإشعارات) — 1 يوم
4. هجرة توقيع `create_ledger_entry` الموسع (D2، بعد B-2) + فتح تعدد العملات المقفل (D3) — **مرحلة 2** بعد قرار المنتج

**معيار قبول الأسبوع:** كل صفوف مصفوفة قسم 2 بحالة «موصول»؛ اختبار تحقق برمز كشف من جهاز بلا حساب (قناة عامة)؛ مرفق مرتبط بقيد مُزامن.

### إصلاحات سحب مرافقة (الخطوة 7.2)
- `sync_engine.dart:147-220`: إضافة سحب `ledger_entries` لكل `business_customer` (آخر 90 يوماً أو منذ آخر checkpoint محلي) — بدونه جهاز ثانٍ لا يرى قيداً (H-4)؛ دمج استعلام الأرصدة في `in(...)` واحد (M-5)؛ تحديث `sync_status` بعد الدفع الناجح (M-6)؛ إطالة الدورة من 30 ثانية (`:54`) إلى 5 دقائق + تشغيل عند الأحداث فقط.

---

## 8. مخاطر وحدود الخطة

1. **B-4 (المصادقة) شرط مسبق فعلي:** كل معايير القبول تفترض جلسات Supabase حقيقية؛ الهويات الوهمية `usr-*/biz-*` (`auth_controller.dart:104,155`) تجعل أي اختبار E2E زائفاً. يجب إغلاق C-9/C-10/C-11 بالتوازي مع الأسبوع 0 كحد أقصى.
2. **عكس/خصم/مرفق على قيد غير مُزامن محظور** حتى اكتمال خريطة `client_request_id → id` (5.8/3.8) — قيد UX مقصود وموثق للمستخدم.
3. **أسماء أعضاء الفريق** تبقى معرّفات مقطعة حتى B-1؛ مقبول للتجريبي المغلق، غير مقبول للإطلاق التجاري.
4. **`full_schema.sql` (M-1) ممنوع** كمرجع عقود — المرجع الوحيد ملفات migrations المرقمة.
5. **تعدد العملات الكامل مؤجل واعٍ** (D3) ويحتاج قرار منتج موثقاً قبل مرحلة 2.

---

*انتهت الخطة — كل مرجع سطر/ملف قابل للتحقق في المسارات المذكورة، وكل خطوة قابلة للإسناد والاختبار المستقل.*
