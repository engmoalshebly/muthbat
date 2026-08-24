# تقرير تدقيق التوثيق مقابل التنفيذ — نظام دفتر الديون

> **المدقق:** مدقق_التوثيق_مقابل_التنفيذ (Docs vs Implementation Auditor)
> **النطاق:** مطابقة محتوى `debt-ledger-supabase/docs/` مع الترحيلات الفعلية في `supabase/migrations` (12 ملفاً) ودوال Edge في `supabase/functions` (9 دوال + `_shared`) واختبارات `supabase/tests/database`.
> **المنهجية:** قراءة كاملة لكل الوثائق التسع وكل ملفات الترحيلات الاثني عشر وكل نقاط دخول Edge Functions، ثم مطابقة الأسماء (جداول/دوال/حقول/أنواع)، تسلسل العمليات، ووعود الوثائق مقابل سلوك الكود الفعلي سطراً بسطر.

**التصنيفات:** [حرج] يمنع الإطلاق أو يكسر النظام/الأمان · [عالي] وعد موثق غير متحقق أو توثيق مضلل جوهرياً · [متوسط] اختلاف حقيقي يحتاج تصحيحاً قبل الإطلاق · [منخفض] قِدَم توثيقي شكلي · [إيجابي] مطابقة مؤكدة تستحق التثبيت.

---

## 1. ملخص الأعداد

| التصنيف | العدد |
|---|---:|
| حرج | 3 |
| عالي | 4 |
| متوسط | 10 |
| منخفض | 4 |
| إيجابي | 7 |
| **الإجمالي** | **28** |

---

## 2. الملاحظات الحرجة [حرج]

### C-1 — الترحيل `202608180012_multi_currency_and_categories.sql` غير موثق إطلاقاً ومكسور بنيوياً
**الملف:** `supabase/migrations/202608180012_multi_currency_and_categories.sql`

هذا الترحيل (بتاريخ 2026-08-18) لا تذكره أي وثيقة: `api-reference-and-operational-flow.md:3` يقول «مطابق للـ Backend الحالي حتى الترحيل `011`»، و`database-architecture-and-operations-spec.md:256-268` يسرد الترحيلات حتى `011` فقط، و`full_schema.sql` (3070 سطراً) ينتهي عند الترحيل `011` ولا يتضمنه. فوق كونه غير موثق، فهو **مكسور** بعدة طرق مستقلة:

1. **سيفشل الترحيل نفسه عند التطبيق:** السطر 41 ينشئ سياسة RLS تستدعي `public.has_business_permission(business_id, 'view_balances'::public.business_permission)` — وهذه الدالة وهذا النوع **غير موجودان** في أي ترحيل من `001` إلى `011` (بحث شامل في المستودع لا يجد لهما أي تعريف). إنشاء السياسة سيفشل، وبالتالي فالترحيل `012` لا يمكن تطبيقه على قاعدة بيانات مطابقة للترحيلات السابقة.
2. **دالة عامة جديدة بلا فحص صلاحية الدور:** الأسطر 114-129 تنشئ `public.command_create_ledger_entry(...)` — باسم يصطدم بنمط التسمية الموثق (`private.command_*` + غلاف `public.create_ledger_entry`) — وتتحقق فقط من أن المحل نشط (الأسطر 142-144) **دون أي استدعاء لـ `is_business_member`**، أي بلا تحقق من عضوية أو دور المستخدم، وهو ما تفرضه كل الأوامر الموثقة (`database-architecture-and-operations-spec.md:29` «الأوامر هي بوابة الكتابة»). ولأن الترحيل لا يتضمن أي `revoke`، فالدالة تأخذ منح التنفيذ الافتراضي لـ PUBLIC في PostgreSQL.
3. **قيم اتجاه غير صالحة:** الأسطر 157-163 تعيّن الاتجاه `'in'`/`'out'`، بينما النوع الفعلي `public.ledger_direction` هو `('debit','credit')` (`202607120001_core_schema.sql:20`). أي إدراج عبر هذه الدالة سيفشل بخطأ enum. كذلك تفترض `entry_type = 'fee'` (سطر 157) غير الموجود في `ledger_entry_type` (`001:19` + `009:3`).
4. **مرجع أجنبي خاطئ:** سطر 17 يربط `customer_currency_balances.customer_id` بـ `public.profiles(id)`، بينما كل المخطط يربط هوية العميل بـ `public.customers(id)` (انظر `erd.md:6` و`001:69-78`).
5. **تريجر لا يعمل أبداً:** سطر 59 يقارن `new.direction = 'in'` — شرط لا يتحقق أبداً لأن القيم الفعلية `debit/credit`، فتُحسب كل القيود كدائن.
6. **عدم اتساق الأنواع:** المعامل `p_source_device_id text` (سطر 128) بينما العمود `uuid` (`001:173`)، و`p_description text default ''` (سطر 123) يخالف قيد الطول `between 2 and 500` (`001:167`).

**الأثر قبل الإطلاق:** إما أن الترحيل لم يُطبَّق فعلاً (فالوثائق والكود المنشور يمثلان الحقيقة ويجب حذف/إعادة كتابة 012)، أو طُبِّق جزئياً في بيئة ما (فهناك انحراف خطير عن المعمارية الموثقة). في الحالتين يجب حسمه قبل أي إطلاق تجاري.

### C-2 — `process-automation-rules` موثق كعامل جاهز لكنه مكسور وقت التشغيل في مساريه كليهما
**الملف:** `supabase/functions/process-automation-rules/index.ts`
**الوثائق المتأثرة:** `first-version-product-architecture-spec.md:401` («تنفيذ التذكيرات والتصعيدات المجدولة»)، `functions/README.md:35-39` («Background worker … Dispatches in-app notifications and reminder records»)، `api-reference-and-operational-flow.md:126`.

1. **إدراج في `reminders` بأعمدة غير موجودة:** الأسطر 213-221 تدرج `ledger_entry_id` و`title` و`body` في جدول `reminders`، بينما الجدول الفعلي (`202607120001_core_schema.sql:326-338`) أعمدته: `business_id, business_customer_id, sent_by_user_id (NN), channel, message_snapshot (NN), status, scheduled_at, sent_at`. لا يوجد `ledger_entry_id` ولا `title` ولا `body`، والإدراج يغفل العمودين الإلزاميين `sent_by_user_id` و`message_snapshot`. كل تنفيذ لقاعدة استحقاق سيفشل بخطأ عمود غير موجود.
2. **استعلام اعتراضات بعمود غير موجود:** السطر 274 يطلب `status` ضمن select من `disputes` والسطر 281 يرشّح `.in("status", ...)`، بينما جدول `disputes` لا يملك عمود `status` إطلاقاً؛ الحالة في `dispute_state` (`001:227-234`). مسار `dispute_sla` كامل سيفشل.
3. **إشعارات بلا outbox:** الأسطر 225-237 و325-331 تدرج مباشرة في `notifications` متجاوزة `private.enqueue_notification` (`202607120002_functions_and_triggers.sql:88-111`)، فلا يُنشأ صف في `private.notification_outbox`، وبالتالي **لن يصل أي Push إطلاقاً** عبر `process-notification-outbox`. هذا يناقض دورة الإشعار الموثقة صراحة: «إدراج إشعار ومهمة في نفس المعاملة» (`first-version-product-architecture-spec.md:416`).

**الأثر:** ميزة «قواعد تذكير تلقائية أولية» المعلنة ضمن نطاق النسخة الأولى (`first-version-product-architecture-spec.md:55`) غير عاملة فعلياً رغم أن الوثائق تعرضها كمنفذة.

### C-3 — دالة `send-whatsapp-otp` غير موثقة إطلاقاً، بأسرار مضمّنة في الكود، وبلا أي حماية
**الملف:** `supabase/functions/send-whatsapp-otp/index.ts`

1. **غير موثقة:** لا تظهر في أي قائمة موثقة — لا في `edge-functions.md` (6 دوال)، ولا في `first-version-product-architecture-spec.md:394-404` (9 دوال)، ولا في `api-reference-and-operational-flow.md:47-53,123-127`.
2. **تخالف النطاق الموثق صراحة:** «WhatsApp/SMS جماعي مدفوع» خارج النطاق (`first-version-product-architecture-spec.md:65`؛ و`First-version.md:121` «رسائل واتساب آلية مدفوعة» غير مشمولة).
3. **أسرار افتراضية مضمّنة في الشيفرة:** السطر 4 يضمّن `OPENWA_SESSION_ID` افتراضياً، والسطر 5 يضمّن **مفتاح API كامل** `owa_k1_18037727b0f4...` كنص صريح. هذا يناقض مبدأ «المفاتيح السرية تبقى فقط في Edge Functions [كأسرار بيئة]» (`edge-functions.md:41-43`)، وهو تسريب فعلي لبيانات اعتماد في المستودع يجب إبطاله فوراً.
4. **بلا مصادقة ولا تحديد معدل:** الدالة لا تستدعي `requireUser` ولا `requireWorkerSecret` ولا `service_consume_rate_limit` — أي شخص يعرف عنوان الدالة يستطيع إرسال رسائل واتساب عبر حساب المنصة لأي رقم، وهو ما تفرض الوثائق منعه صراحة: «Rate limiting لطلب OTP» (`first-version-product-architecture-spec.md:447`) و«منع طلب OTP بصورة مفرطة» (`First-version.md:1316`).

---

## 3. الملاحظات العالية [عالي]

### H-1 — الوثائق تدّعي أن `generate-statement` غير منفذ (501) بينما هو منفذ بالكامل فعلياً
- `api-reference-and-operational-flow.md:127`: «موجود لكنه يعيد `501 statement_generation_pending` … PDF غير منفذ».
- `database-architecture-and-operations-spec.md:21`: «مولّد PDF النهائي لكشف الحساب» ضمن «النطاق المؤجل عمداً»، والسطر 290 يطلب «جعل `generate-statement` يولّد PDF فعلياً» كعمل مستقبلي.
- **الواقع:** `supabase/functions/generate-statement/index.ts` (562 سطراً) منفذ بالكامل: ينشئ اللقطة عبر `create_statement` (سطر 433)، يولّد PDF متعدد الصفحات بـ pdf-lib (الأسطر 58-412)، يرفعه إلى bucket `statements` (الأسطر 509-514)، يقفل SHA-256 عبر `service_attach_statement_document` (الأسطر 519-525)، ويعيد رابطاً موقعاً لمدة ساعة (الأسطر 528-552) — مطابق تماماً لما توثقه `edge-functions.md:33-35`.
- **الأثر:** وثيقتان مرجعيتان للإطلاق تصفان ميزة أساسية (كشف الحساب PDF) كغير موجودة — قرار إطلاق مبني عليهما سيكون خاطئاً في الاتجاهين.

### H-2 — الوثائق تدّعي أن `process-automation-rules` يعيد `ready_not_activated` بينما هو منشّر كنشط
- `api-reference-and-operational-flow.md:126`: «موجود لكنه يعيد `ready_not_activated`؛ لا يُشغل التذكيرات بعد».
- **الواقع:** `process-automation-rules/index.ts` منفذ بمنطق كامل (376 سطراً) ويعيد `status: "completed"` مع عدّادات (الأسطر 360-366) — لكنه مكسور داخلياً (انظر C-2). الوثيقة إذن مخطئة مرتين: تصفه كمعطّل، والصحيح أنه «مفعّل ظاهرياً وفاشل فعلياً» — وهي حالة أخطر من المعطّل لأنها تعطي ثقة زائفة.

### H-3 — PDF كشف الحساب إنجليزي فقط وبخط لا يدعم العربية، مخالفاً وعد «العربية أولاً»
- **الوعد الموثق:** «العربية وRTL أولاً» (`first-version-product-architecture-spec.md:58`)، وشاشة كشف الحساب تتضمن «لغة الكشف» (`First-version.md:472`)، وكشف يعرض وصف العمليات العربية (`First-version.md:874-891`).
- **الواقع:** `generate-statement/index.ts:65-66` يضمّن `StandardFonts.Helvetica` فقط، وكل النصوص الثابتة إنجليزية («ACCOUNT STATEMENT / FINANCIAL RECORD» سطر 86، وعناوين الأعمدة الأسطر 235-241). pdf-lib بالخطوط القياسية **لا يستطيع تشكيل الحروف العربية**؛ وصف القيد العربي (`description_snapshot`) سيظهر حروفاً مشوهة/مقلوبة في وثيقة مالية رسمية موقعة يفترض أنها «كشف حساب رسمي» (`first-version-product-architecture-spec.md:31`).
- **الأثر:** الميزة «منفذة» تقنياً لكنها لا تفي بالوعد المنتجي/التجاري الموثق — مانع إطلاق في سوق عربي.

### H-4 — دالة `cleanup-expired-data` موثقة وغير موجودة
- **الوعد:** `first-version-product-architecture-spec.md:404` يسرد `cleanup-expired-data` ضمن دوال Edge التسع: «إغلاق روابط ومهام منتهية وتنظيف آمن».
- **الواقع:** لا يوجد مجلد بهذا الاسم في `supabase/functions`. يوجد تعويض جزئي غير موثق بديلاً عنها: مهمتا pg_cron `expire-customer-link-requests` (`202607120005_operations_audit.sql:142-144`) و`expire-business-member-invites` (`202608140008_member_invites_and_statement_commands.sql:110-112`) — لكنهما لا تغطيان «المهام المنتهية والتنظيف الآمن» (مثل `upload_sessions` المنتهية التي لها فهرس `idx_upload_sessions_owner_expiry` في `202608140006:128` بلا أي منظّف).

---

## 4. الملاحظات المتوسطة [متوسط]

### M-1 — جداول موثقة كمطلوبة للنسخة الأولى وغير منفذة: `dispute_sla` و`security_events` و`business_settings`
`first-version-product-architecture-spec.md:349,358,359` تسردها ضمن «الجداول الواجب إضافتها». لا وجود لها في الترحيلات. جزء من وظيفة `dispute_sla` مغطى بـ `automation_rules.trigger_type='dispute_sla'` (`202608140006:55`) لكن بلا جدول SLA مستقل، و`security_events` (تغيير هاتف/إبطال جهاز/حظر) غائبة كلياً رغم كونها جزءاً من قصة الأمان الموثقة (`first-version-product-architecture-spec.md:441`).

### M-2 — الترحيل 012 يخالف المبدأ الموثق «الرصيد يُشتق ولا يُخزن»
`first-version-product-architecture-spec.md:364`: «رصيد العميل يشتق من القيود ولا يحفظ كرقم قابل للتحرير»، و`database-architecture-and-operations-spec.md:177` يؤكد أن الرصيد «يحسب من دفتر الأستاذ لا من قيمة مخزنة». الترحيل `012:13-26` ينشئ `customer_currency_balances.current_balance` كرصيد **مخزن** يحدّثه تريجر (`012:51-111`) — انحراف معماري غير موثق عن مبدأ تأسيسي.

### M-3 — تعدد العملات في 012 يخالف قرار «عملة واحدة لكل محل» الموثق
القرار معتمد صراحة: `first-version-product-architecture-spec.md:64` («تعدد العملات داخل المحل» خارج النطاق) و`:540` (قرار معتمد)، و`database-architecture-and-operations-spec.md:76`، و`api-reference-and-operational-flow.md:276` («الدفع متعدد العملات يحتاج مرحلة مستقلة»). الترحيل 012 يضيف أعمدة عملة/تصنيف/طريقة دفع لكل قيد (`012:5-10`) وجدول أرصدة لكل عملة (`012:13-26`) ودالة تقبل `p_currency_code` (`012:118`) — كل ذلك بلا أي تحديث للوثائق ولا لاختبارات قاعدة البيانات.

### M-4 — وثيقة معمارية قاعدة البيانات متناقضة داخلياً حول حدود الترحيلات وأسماء الملفات
- `database-architecture-and-operations-spec.md:3`: «مطابق للترحيلات `001` إلى `008`»، بينما §13 (الأسطر 256-268) يسرد الترحيلات حتى `011`.
- أسماء الملفات في §13 لا تطابق الفعلية: الموثق `202607120003_rls_policies.sql` / `202607120004_jobs_and_storage.sql` / `202607120005_rls_hardening.sql`، والفعلي `202607120003_rls_and_grants.sql` / `202607120004_storage_realtime.sql` / `202607120005_operations_audit.sql`.
- لا ذكر للترحيل `012` (انظر C-1).

### M-5 — قاموس أنواع القيود في الوثيقة ناقص قيمة `discount`
`database-architecture-and-operations-spec.md:68` يسرد «نوع السجل المالي: `opening_balance`, `debt`, `payment`, `reversal`»، بينما الترحيل `202608140009_ledger_discount_enum.sql:3` أضاف `discount`، والقيد المحدّث في `202608140010:314-319` يشمله. الوثيقة نفسها تذكر الخصم في أماكن أخرى (سطر 32) — تناقض داخلي.

### M-6 — تعارض داخلي بين الوثائق حول الدفع الأكبر من الرصيد
`First-version.md:1043`: «منع تسجيل دفعة أكبر من الرصيد الحالي» (قرار MVP). التنفيذ في `202608140010:366-367` يسمح بالتجاوز افتراضياً (`allow_customer_credit_balance=true` الافتراضي، سطر 39)، و`api-reference-and-operational-flow.md:188` يوثق السماح. إحدى الوثيقتين يجب أن تُصحح؛ حالياً يستحيل معرفة السلوك «المقصود» منتجياً.

### M-7 — `First-version.md` يقترح بنية خادم مختلفة كلياً (NestJS/Laravel/Django)
`First-version.md:1689-1695` يقترح NestJS مع TypeScript كخادم، و`First-version.md:1707` يحدد FCM فقط للإشعارات. التنفيذ الفعلي Supabase (PostgreSQL + RPC + Edge Functions) كما تقرره `first-version-product-architecture-spec.md:538`. الوثيقة التحليلية الأصلية لم تُحدَّث وقد تضلل أي منفذ جديد.

### M-8 — `edge-functions.md` يسرد 6 دوال فقط من أصل 9 منشورة
الوثيقة (`edge-functions.md:3-39`) تغطي: bootstrap-user-contact، customer-directory، signed-document-upload، process-notification-outbox، generate-statement، verify-statement. **الناقص:** `finalize-document-upload` (منفذة وموثقة في api-reference:52!)، `process-automation-rules`، و`send-whatsapp-otp` (انظر C-3). ملاحظة: `functions/README.md` أدق (يغطي 8) لكنه يغفل `send-whatsapp-otp` أيضاً.

### M-9 — قائمة RPC في وثيقة المنتج ناقصة 4 أوامر منفذة
`first-version-product-architecture-spec.md:375-390` تسرد 14 RPC. المنفذ فعلياً وغير المذكور فيها: `apply_customer_discount` (`202608140010:404`)، `create_statement` (`202608140008:185`)، `post_manual_journal` (`202608140010:438`)، `close_accounting_period` (`202608140010:461`). الوثيقتان الأحدث (`database-architecture...:185-197` و`api-reference...:143-213`) تغطيانها — أي وثيقة المنتج هي المتخلفة.

### M-10 — RPCs موثقة في وثيقة المنتج وغير منفذة: `create_reminder` و`mark_notification_read`
`first-version-product-architecture-spec.md:388-389` تسردهما ضمن «RPC المتاحة للتطبيق». لا وجود لهما في الترحيلات. البديل الفعلي: كتابة مباشرة بـ RLS على `reminders` (`202607120003:52,184-190`) وتحديث `notifications.read_at` (`202607120003:51,181-182`) — وهو ما توثقه `api-reference-and-operational-flow.md:235` فعلاً. النتيجة: وثيقتان مرجعيتان تعطيان عقدين مختلفين للتطبيق.

---

## 5. الملاحظات المنخفضة [منخفض]

### L-1 — أرقام الاختبارات الموثقة قديمة
`database-architecture-and-operations-spec.md:280`: «ملفا اختبار و21 assertion». الفعلي: 3 ملفات (`001_schema_contract.sql` خطة 10، `002_core_workflow.sql` خطة 11، `003_double_entry_accounting.sql` خطة 10) = **31 assertion**.

### L-2 — مخططا ERD غير محدثين
`erd.md` (نسخة MVP) و`database-architecture-and-operations-spec.md:38-58` لا يشملان: `business_member_invites`، `device_installations`، `command_receipts`، `sync_checkpoints`، `business_automation_settings`، `automation_rules`، `automation_runs`، `upload_sessions`، وجداول المحاسبة الخمسة، و`customer_currency_balances`.

### L-3 — مرجع API يذكر Expo فقط لعامل الإشعارات
`api-reference-and-operational-flow.md:125`: «يرسل Expo عند ضبط `PUSH_PROVIDER=expo`». التنفيذ يدعم `fcm` (Legacy وHTTP v1) و`expo` و`in_app`/`mock` (`process-notification-outbox/index.ts:141,172-177`).

### L-4 — `full_schema.sql` لا يشمل الترحيل 012
`database-architecture-and-operations-spec.md:270` تعرّفه كـ«نسخة مجمّعة … من هذه الترحيلات». الملف (3070 سطراً) ينتهي عند محتوى `011`. هذا متسق مع تجاهل الوثائق لـ 012 لكنه يعني أن 012 خارج كل مراجع الحقيقة الثلاثة (وثائق/مخطط مجمع/اختبارات).

---

## 6. المطابقات الإيجابية [إيجابي]

### P-1 — كل RPCs الموثقة في مرجع API منفذة فعلاً بنفس الأسماء والمعاملات والأدوار
طابقتُ `api-reference-and-operational-flow.md:143-213` مع الترحيلات: `create_business` (`002:174`)، `invite_business_member`/`respond_business_member_invite` (`008:60,91`)، `add_business_customer` (`002:226`)، `request_customer_link`/`respond_link_request` (`002:263,294` + إصلاح `007:4`)، `create_ledger_entry` (`002:413` محدثة في `010:346`)، `apply_customer_discount` (`010:404`)، `reverse_ledger_entry` (`002:453` محدثة في `007:65`)، `confirm_ledger_entry` (`002:496` محدثة في `006:339`)، `open_dispute`/`add_dispute_message`/`resolve_dispute` (`002:530,563,606` محدثة في `006/007`)، `create_statement` (`008:185`)، `post_manual_journal`/`close_accounting_period` (`010:438,461`) — مع منح تنفيذ مطابقة (`003:56-65`، `008:207-209`، `010:505-507`). الأدوار في كل أمر تطابق الجداول الموثقة.

### P-2 — المبادئ المالية غير القابلة للتنازل منفذة كما وُثقت
عدم التعديل/الحذف عبر `prevent_update_delete` على الجداول السبعة (`001:442-452`)، `numeric(20,4)` للمبالغ (`001:165`)، تفرد `(business_id, client_request_id)` (`001:176`) مع إعادة النتيجة السابقة (`006:274-276`)، تفرد `reversal_of_entry_id` (`001:171`)، منع عكس العكس (`010:338`)، مطابقة العكس للأصل مبلغاً وعملةً واتجاهاً معاكساً (`010:339-340`)، حظر التأكيد مع اعتراض نشط (`006:352-354`)، ومنع الرسائل/الحل بعد الحالة النهائية (`006:405-407,455-457`) — كلها تطابق `first-version-product-architecture-spec.md:33-41,361-369`.

### P-3 — مصفوفة RLS الموثقة تطابق التنفيذ
`rls-matrix.md:17-24` (الأدوار) تطابق قوائم الأدوار في الدوال: العكس owner/admin/accountant (`007:73`)، التأكيد والاعتراض للعميل فقط (`006:346-349,368-371`)، رسائل الاعتراض تشمل collector (`006:410`)، وتذكيرات collector مسموحة (`003:187`) — وكل جداول `public` عليها RLS (`003:5-27`).

### P-4 — كل دوال `service_*` الموثقة موجودة ومقيدة بـ `service_role`
`service_find_customer_by_phone_hash`، `service_upsert_customer_contact` (`003:86-92`)، `service_claim/complete/fail_notification` (`005:148-159`)، `service_consume_rate_limit` و`service_record_notification_delivery_attempt` (`006:550-557`)، `service_attach_statement_document` (`008:214-217`) — مطابقة لـ `database-architecture-and-operations-spec.md:197` و`api-reference-and-operational-flow.md:308`.

### P-5 — `verify-statement` يطابق المواصفة حرفياً
GET عام، تحقق من صيغة الرمز، rate limit لكل IP (30/ساعة)، ويعيد فقط: validity، التواريخ، العملة، الرصيد الختامي، بصمة المستند — بلا أي PII (`verify-statement/index.ts:10-19`)، مطابق لـ `edge-functions.md:37-39` و`api-reference-and-operational-flow.md:104-119`.

### P-6 — مواصفة المحاسبة المزدوجة دقيقة ومطابقة للتنفيذ والاختبارات
`double-entry-accounting-spec.md` تطابق الترحيل `010`: دليل الحسابات الخمسة (`010:133-139`)، الحساب الضابط 1100 بلا قيد يدوي (`010:136`)، قيود الدين/الدفعة/الخصم/العكس (`010:276-296,263-274`)، الاتزان المؤجل (`010:219-221`)، قفل الفترات (`010:167-176`)، وعدم قابلية التعديل (`010:121-124`) — واختبار `003_double_entry_accounting.sql` يغطي ما تعد به الأسطر 112-119 فعلاً.

### P-7 — دوال الهوية والدليل والرفع تطابق توثيقها
`bootstrap-user-contact` (E.164 + HMAC + AES-GCM، `bootstrap-user-contact/index.ts:15-26`) مطابق لـ `edge-functions.md:3-9`؛ `customer-directory` (rate limit 60/ساعة، تحقق عضوية بأدوار محددة، إنشاء عميل غير مسجل، ربط اختياري، `customer-directory/index.ts:21-51`) مطابق لـ `api-reference-and-operational-flow.md:50,55-80`؛ وثنائي الرفع `signed-document-upload`/`finalize-document-upload` (جلسة 15 دقيقة، 10 MiB، تحقق حجم وبصمة SHA-256) مطابق لـ `api-reference-and-operational-flow.md:82-102` وقيد الجلسة في `202608140006:79-93`.

---

## 7. مصفوفة الجداول: موثق مقابل منفذ

| الجدول | موثق في | منفذ في | الحالة |
|---|---|---|---|
| profiles, customers, private.customer_contacts, user_consents, device_push_tokens | product-spec §10.1 / db-spec §5 | 001 | ✓ مطابق |
| businesses, business_members, business_customers, customer_link_requests | §10.1 / §5 | 001 | ✓ مطابق |
| ledger_entries, ledger_entry_state, ledger_entry_events, entry_confirmations | §10.1 / §5 | 001 | ✓ مطابق (مع إضافة `discount` غير الموثقة في §4 — M-5) |
| disputes, dispute_state, dispute_events, dispute_messages | §10.1 / §5 | 001 | ✓ مطابق |
| files, ledger_entry_files, dispute_message_files | §10.1 / §5 | 001 | ✓ مطابق |
| notifications, private.notification_outbox, reminders | §10.1 / §5 | 001 | ✓ مطابق |
| statements, statement_items, private.audit_logs | §10.1 / §5 | 001 | ✓ مطابق |
| business_member_invites | §10.2 (مطلوب) | 008 | ✓ أُضيف |
| business_automation_settings, automation_rules, automation_runs | §10.2 (مطلوب) | 006 | ✓ أُضيف |
| notification_delivery_attempts, dead_letter_jobs | §10.2 (مطلوب) | 006 | ✓ أُضيف |
| device_installations, command_receipts, sync_checkpoints | §10.2 (مطلوب) | 006 | ✓ أُضيف |
| upload_sessions | db-spec §5 | 006 | ✓ مطابق |
| rate_limit_windows | db-spec §6 | 006 | ✓ مطابق |
| **business_settings** | §10.2 (مطلوب) | — | ✗ غير منفذ (M-1) |
| **dispute_sla** | §10.2 (مطلوب) | — | ✗ غير منفذ (M-1) |
| **security_events** | §10.2 (مطلوب) | — | ✗ غير منفذ (M-1) |
| chart_of_accounts, business_accounting_settings, accounting_periods, journal_entries, journal_entry_lines | db-spec §5 «المحاسبة المزدوجة» / double-entry-spec | 010 | ✓ مطابق |
| **customer_currency_balances** | — (لا وثيقة) | 012 | ✗ منفذ بلا توثيق ومكسور (C-1) |

## 8. مصفوفة Edge Functions: موثق مقابل منفذ

| الدالة | edge-functions.md | product-spec §11.2 | api-reference §3 | منفذة فعلاً | الحالة |
|---|---|---|---|---|---|
| bootstrap-user-contact | ✓ | ✓ | ✓ | ✓ | ✓ مطابقة (P-7) |
| customer-directory | ✓ | ✓ | ✓ | ✓ | ✓ مطابقة (P-7) |
| signed-document-upload | ✓ | ✓ | ✓ | ✓ | ✓ مطابقة (P-7) |
| finalize-document-upload | ✗ (M-8) | ✓ | ✓ | ✓ | ✓ مطابقة، توثيق قديم ناقص |
| process-notification-outbox | ✓ | ✓ | ✓ | ✓ | ✓ مطابقة (مع L-3) |
| generate-statement | ✓ | ✓ | ✗ يدّعي 501 (H-1) | ✓ | ⚠ منفذة، الوثائق مضللة + PDF غير عربي (H-3) |
| verify-statement | ✓ | ✓ | ✓ | ✓ | ✓ مطابقة (P-5) |
| process-automation-rules | ✗ (M-8) | ✓ | ✗ يدّعي معطّل (H-2) | ✓ مكسور | ✗ C-2 |
| **cleanup-expired-data** | ✗ | ✓ | ✗ | ✗ | ✗ موثقة غير منفذة (H-4) |
| **send-whatsapp-otp** | ✗ | ✗ | ✗ | ✓ | ✗ منفذة بلا توثيق + أسرار مضمّنة (C-3) |

---

## 9. التوصيات قبل الإطلاق التجاري (مرتبة)

1. **حسم الترحيل 012 فوراً:** إما حذفه/إعادة كتابته كترحيل `013` سليم (إصلاح `has_business_permission`، الاتجاهات، المرجع الأجنبي، فحص الدور، والمنح) مع توثيقه، أو استبعاده نهائياً وتوثيق الاستبعاد. لا يجوز إطلاق منتج مالي وفي خط ترحيلاته ملف لا يمكن تطبيقه ولا تذكره الوثائق.
2. **إصلاح `process-automation-rules`** (أعمدة `reminders` الصحيحة `message_snapshot`/`sent_by_user_id`، استعلام الحالة من `dispute_state`، والإشعارات عبر `enqueue_notification`) أو تعطيله صراحة وتوثيق التعطيل.
3. **سحب `send-whatsapp-otp` أو إخضاعها:** إبطال مفتاح OpenWA المسرَّب في الكود فوراً، نقله للأسرار، إضافة مصادقة وrate limit، وتوثيق الدالة أو حذفها التزاماً بالنطاق الموثق.
4. **تحديث `api-reference-and-operational-flow.md` و`database-architecture-and-operations-spec.md`** لتعكسا الحالة الفعلية لـ `generate-statement` و`process-automation-rules` والترحيلات حتى 011/012 وأسماء الملفات الصحيحة وأرقام الاختبارات.
5. **حل مشكلة عربية PDF** (تضمين خط عربي TTF ودعم RTL/تشكيل) قبل اعتبار كشف الحساب جاهزاً تجارياً.
6. **توحيد عقد الأوامر:** حسم `create_reminder`/`mark_notification_read` (RPC أم كتابة مباشرة) وتحديث `first-version-product-architecture-spec.md` §11.1 بقائمة RPC الكاملة، وحسم سياسة الدفع الأكبر من الرصيد بين `First-version.md` والتنفيذ.
7. **تحديث `edge-functions.md` و`erd.md`** لتغطية الدوال التسع والجداول الجديدة.

---

*انتهى التقرير — أُنجز بقراءة مباشرة لكل الملفات المذكورة دون افتراض محتوى من الأسماء.*
