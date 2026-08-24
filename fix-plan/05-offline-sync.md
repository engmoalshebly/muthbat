# خطة إصلاح محرك المزامنة الأوفلاين (Offline Sync Remediation Plan)

**الدور:** مخطط_إصلاح_المزامنة (Offline Sync Remediation Architect)
**التاريخ:** 2026-08-18
**النطاق:** `mobile/lib/core/sync/sync_engine.dart`، `mobile/lib/core/database/app_database.dart`، `mobile/lib/features/merchant/data/merchant_repository.dart`، `mobile/lib/features/auth/presentation/controllers/auth_controller.dart` (نقطة signOut فقط)، والترحيل `debt-ledger-supabase/supabase/migrations/202608140006_platform_hardening_and_offline.sql` + عقود RPC في الترحيلات الأخرى.
**المرجع:** `analysis-reports/07-mobile-data-layer.md` (الملاحظات ح-1، ح-2، ع-1، ع-2، ع-3، ع-5، ع-6، ع-9، م-1، م-2، م-3، م-6، م-7).

---

## أولاً: تشخيص الحالة الراهنة (مُتحقق منه بالسطور)

| # | المشكلة | الدليل |
|---|---|---|
| 1 | أسماء/معاملات RPC لا تطابق الباكند → فشل دائم `PGRST202` لكل أمر مالي | `sync_engine.dart:122-131` + payloads في `merchant_repository.dart:129-143, 190-196, 259-263` مقابل `public.create_ledger_entry` (`202607120002:413-425`) و`public.apply_customer_discount` (`202608140010:404-408`) و`public.reverse_ledger_entry(p_entry_id,...)` (`202607120002:453-455`) |
| 2 | إضافة عميل لا تدخل الطابور إطلاقاً | `merchant_repository.dart:46-81` (لا إدراج في `offline_mutations_queue`)، ولا `command_type` لإنشاء عميل في `sync_engine.dart:122-132` |
| 3 | السحب لا يجلب `ledger_entries` ولا النزاعات ولا الكشوفات | `sync_engine.dart:147-220` |
| 4 | أرصدة العملات المحلية لا تُحدَّث من السيرفر أبداً | `sync_engine.dart:187-213` يكتب `current_balance` المسطح فقط؛ `local_customer_currency_balances` لا يُمس |
| 5 | كتابة فوقية بلا حل تعارضات | `ConflictAlgorithm.replace` في `app_database.dart:303-310` بلا فحص `updated_at` ولا حماية `sync_status='pending*'` |
| 6 | حذف الطابور عند signOut = فقدان مالي صامت | `auth_controller.dart:505` → `app_database.dart:511-520` |
| 7 | لا حد محاولات ولا dead-letter ولا backoff ولا تمييز 4xx/شبكة | `app_database.dart:496-503`، `sync_engine.dart:136-142`، إعادة كل 30 ثانية (`sync_engine.dart:54`) |
| 8 | الأخطاء تُبتلع وتُرجع `false`/`null`/قوائم فارغة | `merchant_repository.dart:354-356, 374-376, 394-396, 409-411, 428-430, 468-470`؛ الخطأ يُسجَّل في `debugPrint` فقط (`sync_engine.dart:137`) |
| 9 | قيود `reversal` لا تُحدِّث الرصيد المحلي + عملة العكس ثابتة `YER` | `app_database.dart:405-411`، `merchant_repository.dart:232` |
| 10 | معرّفات محلية (`cust-`, `entry-`) لا تُسوَّى مع معرّفات السيرفر | `merchant_repository.dart:54, 100`؛ لا توجد خطوة reconciliation بعد نجاح الإدراج |
| 11 | N+1 في سحب الأرصدة | `sync_engine.dart:185-213` (استعلام view لكل عميل) |
| 12 | ترحيل SQLite هش (ALTER بـ try/catch صامتة، لا onUpgrade) | `app_database.dart:58-72`، `_dbVersion = 2` (سطر 12) |

**نقاط قوة يجب الحفاظ عليها:** الحفظ التفاؤلي + إدراج الطابور في معاملة SQLite واحدة (`app_database.dart:371-474`)، حارس `_isProcessing` (`sync_engine.dart:39, 78-79`)، ترتيب FIFO (`app_database.dart:483`)، وتصميم idempotency عبر `client_request_id` مع قيد فريد في الباكند (`202607120001_core_schema.sql:176`) وجدول `command_receipts` (`202608140006:19-28`).

---

## ثانياً: المعمارية النهائية للمزامنة (نموذج Push/Pull)

### 2.1 قرار معماري: من يتغيّر — العميل أم الباكند؟

- **الخيار أ:** تعديل الباكند ليطابق استدعاءات العميل الحالية (إضافة المعاملات الستة لـ `public.create_ledger_entry`، إعادة تسمية `p_entry_id`...).
- **الخيار ب:** تعديل العميل ليطابق الدوال العامة المنشورة، مع توسعات محدودة ومدروسة في الباكند حيث ينقصه فعلاً capability (عملة الخصم، المرفقات).
- **الخيار ج:** طبقة توافق (adapter) في العميل تترجم الأسماء.

**التوصية: الخيار ب.** المبررات: (1) دوال الباكند العامة مغطاة باختبارات pgTAP وعليها RLS وقيود محاسبية (فحص credit limit ورصيد السداد في `202608140006:280-285`) — تعديل تواقيعها يكسر عقوداً أخرى؛ (2) العميل هو الطرف الخاطئ بوضوح (يرسل معاملات لا وجود لها)؛ (3) طبقة adapter تضيف سطح فشل ثالثاً بلا قيمة. الاستثناءان المبرران في الباكند: إضافة `p_currency_code` اختياري لـ `apply_customer_discount` (تعدد العملات ميزة مُصدَّرة في `202608180012`)، ومسار المرفقات عبر `upload_sessions` الموجود أصلاً (`202608140006:79-93`) بدل تمرير `p_attachment_path` في RPC.

### 2.2 نموذج Push (ما يُدفع ومتى)

| الأمر | command_type في الطابور | RPC الهدف (عام) | متى يُدفع |
|---|---|---|---|
| إنشاء عميل | `add_business_customer` | `public.add_business_customer` (`202607120002:226-231`) | فور الإنشاء + كل جولة sync |
| قيد دين/سداد | `create_ledger_entry` | `public.command_create_ledger_entry` (`202608180012:114+`) — بلا `p_attachment_path` | فوري + جولات |
| خصم | `apply_customer_discount` | `public.apply_customer_discount` (بعد إضافة `p_currency_code`) | فوري + جولات |
| عكس قيد | `reverse_ledger_entry` | `public.reverse_ledger_entry` بمعامل `p_entry_id` | فوري + جولات |
| رسالة نزاع / حل نزاع / دعوة عضو / كشف | (خارج الطابور — عمليات online-only) | `add_dispute_message`, `resolve_dispute` (`p_resolution_note`), `invite_business_member` (`p_target_user_id`), `create_statement` | مباشرة مع إظهار الخطأ |

**قاعدة الاعتمادية:** أي أمر يشير إلى كيان محلي لم يُزامَن بعد (قيد لعميل `cust-*`، أو عكس لقيد `entry-*`) يحمل `depends_on_client_request_id` ولا يُرسل قبل نجاح اعتماده وتسوية المعرّف (انظر 2.4).

**قاعدة online-only:** عمليات النزاعات والدعوات والكشوفات تتطلب كيانات موجودة على السيرفر أصلاً (dispute_id, entry_id)؛ لا معنى لطابورها أوفلاين. تُنفَّذ مباشرة وتُظهر خطأ واضحاً عند غياب الشبكة بدل `return false` الصامت.

### 2.3 نموذج Pull (ما يُسحب ومتى)

يُسحب بعد اكتمال Push في كل جولة، وبترتيب: محلات → عملاء → قيود → أرصدة عملات → نزاعات.

| الكيان | المصدر | الأسلوب |
|---|---|---|
| المحلات | `business_members` + `businesses(*)` | كما هو (`sync_engine.dart:156-176`) |
| العملاء | `business_customers` | كما هو، مع حماية السجلات `pending` من الكتابة الفوقية |
| القيود المالية | `ledger_entries` (قراءة مسموحة بسياسة `ledger_entries_select_allowed` في `202608140006:488-489`) | **سحب تزايدي** بمؤشر `updated_at/created_at > cursor`، والمؤشر يُخزَّن في `public.sync_checkpoints` الموجود أصلاً (`202608140006:30-38`) لكل (user, device, business) |
| أرصدة العملات | view أرصدة العملات المولَّد بتريجر `trig_update_customer_currency_balance` (`202608180012:51+`) | استعلام مجمّع واحد بـ `in_` لكل عملاء المحل (إصلاح N+1) |
| النزاعات | `disputes` + `dispute_state` | سحب دوري خفيف مع الكتابة في `local_disputes` |

### 2.4 تسوية المعرّفات (ID Reconciliation)

جدول محلي جديد `local_id_map(local_id TEXT PRIMARY KEY, server_id TEXT, entity_type TEXT)`. عند نجاح push لأمر إنشاء (عميل/قيد)، يُعاد `uuid` السيرفر من RPC → يُحفظ في `local_id_map` → يُحدَّث `sync_status` إلى `synced` → تُعاد كتابة `p_business_customer_id`/`p_entry_id` في payloads الأوامر المعلّقة المعتمدة قبل إرسالها. هذا يغلق الملاحظة ع-9 ويمنع فشل FK.

---

## ثالثاً: دورة حياة عنصر الطابور

```
pending ──► syncing ──► (نجاح) ──► [حذف من الطابور + تسوية المعرّف + sync_status='synced']
   ▲           │
   │           ├─ خطأ مؤقت (شبكة/5xx/timeout) ──► failed (next_retry_at = now + backoff)
   │           │                                     │
   │           │◄──────── attempt_count < 8 ─────────┘
   │           │
   │           ├─ خطأ دائم (4xx/PGRST202/42501/22023/55000) ──► dead_letter فوراً
   │           │
   └───────────┴─ attempt_count >= 8 ──► dead_letter
```

**أعمدة جديدة في `offline_mutations_queue`:** `status TEXT DEFAULT 'pending'`، `next_retry_at TEXT`، `last_error_code TEXT`، `server_entity_id TEXT`، `depends_on_client_request_id TEXT`.

**سياسة Backoff:** تصاعدية أسّية `2^attempt` دقيقة بحد أقصى 30 دقيقة (1د، 2د، 4د، 8د، 16د، 30د...) مع jitter عشوائي ±20%، وحد أقصى **8 محاولات** — نفس سياسة الباكند للإشعارات (`202608140006:225-237`) لتوحيد النمط. المزامنة الدورية كل 30 ثانية تلتقط فقط عناصر `pending` أو `failed` المستحقة (`next_retry_at <= now`)، فلا يعود العنصر المعطوب يُرسل كل 30 ثانية.

**dead_letter:** العنصر لا يُحذف أبداً؛ يبقى مرئياً للمستخدم في شاشة "عمليات تحتاج مراجعة" مع سبب الفشل، وخيارَي "إعادة المحاولة" (تصفير العداد) أو "تجاهل وحذف" (بعد تأكيد صريح لأنه حذف بيانات مالية).

---

## رابعاً: سياسة حل التعارضات لكل كيان

| الكيان | السياسة | المبرر |
|---|---|---|
| `ledger_entries` (القيود المالية) | **Server-wins مطلق** + append-only | القيود لا تُعدَّل بل تُعكس (reversal)؛ السيرفر هو مصدر الحقيقة المحاسبية (قيود double-entry وفحوص الرصيد في `202608140006:280-285`). التعارض الوحيد الممكن هو ازدواج الإرسال، ويحلّه `client_request_id` الفريد — لا merge إطلاقاً |
| الأرصدة (`current_balance`, أرصدة العملات) | **Server-wins دائماً** | الرصيد مشتق من القيود؛ الحساب المحلي تفاؤلي مؤقت فقط. بعد كل pull تُستبدل القيم المحلية بقيم السيرفر، وتُعاد إضافة التعديلات التفاؤلية للعناصر `pending` فقط كطبقة عرض موسومة "غير موثق" |
| `business_customers` (الاسم، الملاحظة، credit_limit) | **Last-write-wins بـ `updated_at`** مع حماية `pending` | بيانات وصفية غير مالية؛ التعديلات عليها نادرة ومتباعدة زمنياً. سجل محلي `sync_status='pending*'` لا يُكتب فوقه أبداً حتى يُزامَن |
| `local_businesses`, `local_profiles` | Server-wins | ملكية وإدارة السيرفر؛ لا تعديل محلي عليها |
| `local_disputes` | Server-wins | دورة حياة النزاع تُدار في الباكند (`command_resolve_dispute`) |

**القاعدة العامة:** في منتج مالي، "السيرفر يكسب" هو الافتراض؛ LWW يُسمح فقط للحقول الوصفية غير المالية.

---

## خامساً: منع فقدان البيانات عند signOut

1. قبل `AppDatabase.instance.clearAll()` (`auth_controller.dart:505`): فحص `getPendingMutationsCount()` + عدد dead-letter.
2. إن كان العدد > 0: **حوار تأكيد إلزامي** بثلاثة خيارات: (أ) "مزامنة الآن ثم خروج" (يفرض triggerSync وينتظر)، (ب) "أرشفة وخروج" (تصدير الطابور + القيود pending إلى ملف JSON في تخزين التطبيق مع توضيح طريقة الاسترجاع)، (ج) إلغاء الخروج. يُمنع الخيار الصامت الحالي منعاً باتاً.
3. عند تسجيل الدخول التالي: إن وُجدت أرشيفة سابقة لنفس المستخدم، تُعرض رسالة استرجاع.

---

## سادساً: كشف الأخطاء الدائمة مقابل المؤقتة

| التصنيف | المؤشرات | السلوك |
|---|---|---|
| **دائم** | `PostgrestException` بكود `PGRST202` (دالة غير موجودة)، HTTP 400/401/403/404/409/422، errcodes `42501` (Not authorized)، `22023` (validation)، `55000` (state)، رسائل "Credit limit exceeded"/"Payment exceeds current balance"/"Entry already reversed" | `dead_letter` فوراً + إشعار المستخدم + لا إعادة محاولة آلية |
| **مؤقت** | `SocketException`/timeout، HTTP 429/5xx، غياب شبكة | `failed` + backoff تصاعدي حتى 8 محاولات |
| **غامض** | أي خطأ آخر | يُعامل كمؤقت لكن بعد 3 محاولات يُصنَّف dead_letter احتياطياً |

التنفيذ: دالة `classifySyncError(Object e) → SyncErrorClass` في `sync_engine.dart` تفحص `PostgrestException.code` و`AuthException` وأنواع socket.

---

## سابعاً: إظهار حالة المزامنة للمستخدم

- توسيع `SyncProgress` (`sync_engine.dart:17-27`) بحقول: `failedCount`, `deadLetterCount`, `lastErrorMessage`, `lastSyncAt`.
- شريط حالة دائم أعلى الشاشة الرئيسية: "متزامن ✓" / "N عملية معلقة" / "N عملية تحتاج مراجعة" (أحمر، ينقل لشاشة dead-letter).
- وسم على كل قيد في القوائم: `pending_insert` → "قيد المزامنة"، `dead_letter` → "فشل الإرسال — اضغط للمراجعة".
- إيقاف كل `return false`/`return []` الصامتة في `merchant_repository.dart` واستبدالها بنوع نتيجة `Result<T, SyncError>` يحمل رسالة قابلة للعرض.

---

## ثامناً: خطوات التنفيذ

### المرحلة فوري — خلال 24 ساعة

**الخطوة 1 — توحيد عقد RPC في محرك المزامنة.**
- **الملف:** `mobile/lib/core/sync/sync_engine.dart:122-132` + `mobile/lib/features/merchant/data/merchant_repository.dart:129-143, 190-196, 259-263, 349, 367-371, 422-424, 452`.
- **التغيير:** `create_ledger_entry` → `command_create_ledger_entry` مع حذف `p_attachment_path` من الـ payload (المرفقات لاحقاً عبر `upload_sessions`)؛ `reverse_ledger_entry`: `p_original_entry_id` → `p_entry_id`؛ `apply_customer_discount`: حذف `p_currency_code` مؤقتاً حتى الخطوة 2؛ استبدال `command_add_dispute_message`→`add_dispute_message`، `command_resolve_dispute`→`resolve_dispute` مع `p_resolution_note` بدل `p_note`، `command_invite_business_member`→`invite_business_member` مع `p_target_user_id`، `command_generate_statement`→`create_statement`.
- **التحقق:** اختبار تكامل يدوي ضد Supabase محلي: تنفيذ كل أمر ونجاحه فعلياً (لا PGRST202 في السجلات) + ظهور السجل في قاعدة البيانات.
- **الاعتماديات:** لا شيء. **الجهد:** 0.5 يوم.

**الخطوة 2 — ترحيل باكند صغير: إضافة `p_currency_code` لـ `apply_customer_discount`.**
- **الملف:** ترحيل جديد `debt-ledger-supabase/supabase/migrations/20260819xxxx_fix_discount_currency.sql`.
- **التغيير:** `create or replace function public.apply_customer_discount(..., p_currency_code varchar default null)` يمرّرها لـ `private.command_apply_customer_discount` (مع توسيعها)، مع الحفاظ على التوافق الخلفي (معامل اختياري في النهاية). ثم إعادة `p_currency_code` لـ payload العميل (`merchant_repository.dart:190-196`).
- **التحقق:** اختبار pgTAP جديد: خصم بعملة USD ينتج قيداً بعملة USD.
- **الاعتماديات:** الخطوة 1. **الجهد:** 0.5 يوم.

**الخطوة 3 — تصنيف الأخطاء وإيقاف إعادة المحاولة للأخطاء الدائمة.**
- **الملف:** `mobile/lib/core/sync/sync_engine.dart:136-142` (كتلة catch).
- **التغيير:** إضافة `classifySyncError()`؛ الخطأ الدائم يضع العنصر في `dead_letter` فوراً (مع سجل السبب) بدل `updateMutationAttempt`؛ المؤقت يزيد العداد ويحسب `next_retry_at`.
- **التحقق:** اختبار وحدة: محاكاة PGRST202 → العنصر يخرج من دورة الإرسال خلال جولة واحدة؛ محاكاة انقطاع شبكة → يبقى ويُعاد.
- **الاعتماديات:** الخطوة 6 (أعمدة الحالة) — يمكن تنفيذها مؤقتاً بشرط على `last_error` النصي إن تعذرت. **الجهد:** 0.5 يوم.

**الخطوة 4 — حارس signOut ضد فقدان البيانات.**
- **الملف:** `mobile/lib/features/auth/presentation/controllers/auth_controller.dart:495-507`.
- **التغيير:** قبل `clearAll()`: فحص عدد العناصر المعلقة/dead-letter؛ إن > 0 إرجاع حالة `requiresSyncConfirmation` تعرض حوار الخيارات الثلاثة (قسم خامساً)؛ الحذف الفعلي فقط بعد اختيار صريح.
- **التحقق:** سيناريو يدوي: إنشاء قيد أوفلاين (وضع طيران) → تسجيل خروج → يظهر التحذير ولا يُحذف الطابور دون اختيار.
- **الاعتماديات:** لا شيء. **الجهد:** 0.5 يوم.

### مرحلة صفر — يحظر الإطلاق

**الخطوة 5 — إدراج إنشاء العميل في الطابور.**
- **الملف:** `mobile/lib/features/merchant/data/merchant_repository.dart:46-81`، `mobile/lib/core/database/app_database.dart`، `mobile/lib/core/sync/sync_engine.dart:122-132`.
- **التغيير:** `addCustomer` يُدرج أمر `add_business_customer` في `offline_mutations_queue` (داخل معاملة واحدة مع الحفظ المحلي) بـ payload مطابق لـ `public.add_business_customer` (`202607120002:226-231`)؛ إضافة معالج له في `_processPendingMutations`؛ عند النجاح تخزين `server_id` في `local_id_map` وتحديث `sync_status='synced'`.
- **التحقق:** وضع طيران → إضافة عميل → إلغاء وضع الطيران → العميل يظهر في `business_customers` على السيرفر و`sync_status` محلياً = synced.
- **الاعتماديات:** الخطوة 6 (مخطط الطابور الجديد). **الجهد:** 1 يوم.

**الخطوة 6 — إعادة بناء مخطط الطابور ودورة الحياة (DB v3).**
- **الملف:** `mobile/lib/core/database/app_database.dart:12, 176-186, 479-509`.
- **التغيير:** رفع `_dbVersion` إلى 3 مع `onUpgrade` منهجي (بدل try/catch الصامتة في `_ensureLatestSchema:58-72`): إضافة أعمدة `status, next_retry_at, last_error_code, server_entity_id, depends_on_client_request_id` لـ `offline_mutations_queue`، إنشاء `local_id_map`، دوال `getDueMutations(now)`، `markMutationSyncing/Failed/DeadLetter/Reconciled`. الاستعلامات تعتمد `status` و`next_retry_at`.
- **التحقق:** اختبار ترقية من قاعدة v2 تحوي بيانات → لا فقدان، الأعمدة موجودة، العناصر القديمة تصبح `pending`.
- **الاعتماديات:** لا شيء. **الجهد:** 1 يوم.

**الخطوة 7 — الاعتماديات بين الأوامر وإعادة كتابة المعرّفات.**
- **الملف:** `mobile/lib/core/sync/sync_engine.dart` (`_processPendingMutations`)، `mobile/lib/features/merchant/data/merchant_repository.dart:84-156, 224-274`.
- **التغيير:** عند إنشاء قيد لعميل `sync_status != 'synced'`، يُحفظ `depends_on_client_request_id` لأمر العميل؛ المحرك يتخطى الأمر المعتمد حتى يُسوَّى؛ بعد نجاح الإنشاء تُعاد كتابة `p_business_customer_id`/`p_entry_id` في payloads المعتمدة من `local_id_map`. عكس قيد محلي لم يُزامَن يعتمد على أمر إنشائه.
- **التحقق:** أوفلاين: إضافة عميل + قيدين + عكس → أونلاين → كلها تنجح بالترتيب ولا فشل FK.
- **الاعتماديات:** الخطوتان 5، 6. **الجهد:** 1.5 يوم.

**الخطوة 8 — سحب القيود المالية وأرصدة العملات.**
- **الملف:** `mobile/lib/core/sync/sync_engine.dart:147-220`، `mobile/lib/core/database/app_database.dart`.
- **التغيير:** في `_pullRemoteUpdates`: سحب `ledger_entries` لكل محل (upsert في `local_ledger_entries` مع `sync_status='synced'`، بلا مساس بصفوف `pending*`)؛ سحب view أرصدة العملات باستعلام مجمّع واحد وكتابة `local_customer_currency_balances` (يغلق ع-3 وم-1 معاً في الجزء الوظيفي؛ التجميع الكامل في الخطوة 13).
- **التحقق:** إنشاء قيد من جهاز/عميل آخر → يظهر في كاش الجهاز الأول بعد جولة sync؛ أرصدة العملات المحلية تطابق السيرفر.
- **الاعتماديات:** الخطوة 6. **الجهد:** 1.5 يوم.

**الخطوة 9 — حماية السجلات pending من الكتابة الفوقية (حل التعارضات).**
- **الملف:** `mobile/lib/core/database/app_database.dart:303-310` (`upsertBusinessCustomer`)، `mobile/lib/core/sync/sync_engine.dart:197-213`.
- **التغيير:** `upsertBusinessCustomer` يفحص أولاً: إن كان السجل الموجود `sync_status LIKE 'pending%'` يُحدَّث فقط الحقول الآمنة (الأرصدة المشتقة من السيرفر لا تُكتب فوق تعديل تفاؤلي — تُخزن في عمود `server_balance` منفصل والعرض = server_balance + دلتا التفاؤل)؛ وإلا replace عادي. تطبيق سياسات قسم رابعاً.
- **التحقق:** تعديل اسم عميل أوفلاين + pull متزامن → الاسم المحلي لا يُفقد؛ رصيد السيرفر يظهر مع وسم "غير موثق" للدلتا.
- **الاعتماديات:** الخطوتان 6، 8. **الجهد:** 1 يوم.

**الخطوة 10 — إصلاح منطق الرصيد المحلي (reversal + عملة العكس).**
- **الملف:** `mobile/lib/core/database/app_database.dart:405-411, 440-444`، `mobile/lib/features/merchant/data/merchant_repository.dart:224-257`.
- **التغيير:** معالجة `entryType == 'reversal'` حسب `direction` (debit → إضافة، credit → طرح) في الجدولين؛ `reverseLedgerEntry` يقرأ `currencyCode` من القيد الأصلي بدل `'YER'` الثابتة (سطر 232).
- **التحقق:** اختبار وحدة: دين 100 USD → عكس → الرصيد المحلي يعود 0 USD.
- **الاعتماديات:** لا شيء. **الجهد:** 0.5 يوم.

**الخطوة 11 — واجهة حالة المزامنة وشاشة dead-letter.**
- **الملف:** `mobile/lib/core/sync/sync_engine.dart:17-27`، ملفات UI جديدة (شريط حالة + شاشة مراجعة)، `mobile/lib/features/merchant/data/merchant_repository.dart` (استبدال `return false` الصامتة بنوع `Result`).
- **التغيير:** توسيع `SyncProgress`، شريط حالة، شاشة "عمليات تحتاج مراجعة" بإعادة محاولة/تجاهل، وسوم القيود.
- **التحقق:** إحداث فشل دائم → الشريط يحمر ويعرض العدد؛ الضغط ينقل للشاشة وتظهر رسالة السيرفر الفعلية.
- **الاعتماديات:** الخطوتان 3، 6. **الجهد:** 1.5 يوم.

**الخطوة 12 — اختبارات تكامل end-to-end إلزامية لكل أمر.**
- **الملف:** `mobile/integration_test/` (جديد) + سكربت CI.
- **التغيير:** سيناريو لكل أمر من أوامر الطابور الستة: إنشاء أوفلاين → sync → تحقق من السيرفر + `command_receipts` (`202608140006:19-28`) + `sync_status='synced'` محلياً. يُشغَّل ضد Supabase محلي في CI.
- **التحقق:** كل الاختبارات خضراء؛ أي كسر عقد مستقبلي يفشل CI.
- **الاعتماديات:** الخطوات 1-10. **الجهد:** 2 يوم.

### مرحلة 1 — تجريبي مغلق

**الخطوة 13 — القضاء على N+1 في سحب الأرصدة.**
- **الملف:** `mobile/lib/core/sync/sync_engine.dart:185-213`.
- **التغيير:** استعلام واحد `in_('business_customer_id', ids)` على view الأرصدة بدل استعلام لكل عميل.
- **التحقق:** قياس: 200 عميل → استعلامان إجمالاً بدل 201. **الاعتماديات:** الخطوة 8. **الجهد:** 0.5 يوم.

**الخطوة 14 — السحب التزايدي عبر `sync_checkpoints`.**
- **الملف:** `mobile/lib/core/sync/sync_engine.dart` + استخدام جدول `public.sync_checkpoints` (`202608140006:30-38`).
- **التغيير:** قراءة/تحديث `cursor_value` لكل (user, device, business)؛ سحب `ledger_entries` حيث `created_at > cursor`؛ تحديث المؤشر بعد نجاح الدفعة.
- **التحقق:** سحبان متتاليان: الثاني لا يعيد جلب قيود قديمة (0 صفوف مكررة). **الاعتماديات:** الخطوة 8. **الجهد:** 1 يوم.

**الخطوة 15 — أرشفة الطابور عند signOut.**
- **الملف:** `mobile/lib/features/auth/presentation/controllers/auth_controller.dart` + خدمة تصدير جديدة.
- **التغيير:** خيار "أرشفة وخروج" يصدّر الطابور + القيود pending إلى JSON مؤرخ، ويعرض رسالة استرجاع عند الدخول التالي.
- **التحقق:** أرشفة → خروج → دخول → استرجاع → العناصر تعود للطابور وتُزامَن. **الاعتماديات:** الخطوة 4. **الجهد:** 1 يوم.

**الخطوة 16 — ضبط `occurred_at` وفحص انحراف الساعة.**
- **الملف:** `mobile/lib/features/merchant/data/merchant_repository.dart:101, 141, 168, 236` + باكند.
- **التغيير:** قياس انحراف ساعة الجهاز عن `now()` السيرفر عند كل sync؛ رفض/تصحيح القيود بانحراف > 5 دقائق في الباكند (guard في `command_create_ledger_entry`).
- **التحقق:** تقديم ساعة الجهاز يوماً → القيد يُرفض برسالة واضحة. **الاعتماديات:** الخطوة 1. **الجهد:** 1 يوم.

### مرحلة 2 — إطلاق تجاري

**الخطوة 17 — تشفير قاعدة SQLite.**
- **الملف:** `mobile/lib/core/database/app_database.dart:11, 22-37`.
- **التغيير:** الانتقال إلى `sqflite_sqlcipher` بمفتاح في Secure Storage؛ ترحيل القاعدة الحالية.
- **التحقق:** فتح ملف .db بأداة SQLite عادية يفشل؛ التطبيق يعمل طبيعياً. **الاعتماديات:** لا شيء (بالتنسيق مع خطة الأمان). **الجهد:** 1 يوم.

**الخطوة 18 — كفاءة المزامنة الدورية.**
- **الملف:** `mobile/lib/core/sync/sync_engine.dart:53-57`.
- **التغيير:** تخطي الجولة عند البطارية المنخفضة/الشبكة المترية ما لم توجد عناصر مستحقة؛ رفع الفترة إلى 60 ثانية عند عدم وجود معلق.
- **التحقق:** قياس استهلاك شبكة/بطارية قبل/بعد. **الاعتماديات:** الخطوة 6. **الجهد:** 0.5 يوم.

**الخطوة 19 — قياسات ومراقبة المزامنة.**
- **الملف:** `mobile/lib/core/sync/sync_engine.dart` + لوحة متابعة.
- **التغيير:** عدادات: نسبة نجاح push، معدل dead-letter لكل command_type، زمن الجولة؛ إرسال ملخص مجهول للمراقبة.
- **التحقق:** ظهور المقاييس في لوحة المراقبة بعد جلسة حقيقية. **الاعتماديات:** الخطوة 11. **الجهد:** 1 يوم.

**الخطوة 20 — تعطيل `offlineMockMode` في الإنتاج.**
- **الملف:** `mobile/lib/core/config/supabase_config.dart:17, 29, 39-48`، `mobile/lib/core/sync/sync_engine.dart:109, 148`.
- **التغيير:** في بناء release يُتجاهل flag المستخدم ويُفرض `false` (أو يُحذف كلياً مع أوضاع mock).
- **التحقق:** بناء release: تفعيل العلم من SharedPreferences لا يوقف الإرسال. **الاعتماديات:** لا شيء. **الجهد:** 0.25 يوم.

---

## تاسعاً: معايير القبول النهائية للمرحلة صفر (بوابة الإطلاق)

1. صفر PGRST202 في سجلات sync خلال اختبار تكامل كامل.
2. إنشاء عميل + 3 قيود + خصم + عكس أوفلاين → مزامنة كاملة بلا تدخل، والأرصدة على السيرفر تطابق العرض المحلي بعد التسوية.
3. فشل دائم مُحدَث (صلاحية مسحوبة) → dead_letter خلال جولة واحدة + إشعار مرئي، ولا إعادة إرسال لاحقة.
4. signOut مع عناصر معلقة → لا حذف صامت تحت أي مسار.
5. Pull يجلب قيداً أُنشئ من جهاز آخر ويحدّث أرصدة العملات.
6. كل اختبارات التكامل (الخطوة 12) خضراء في CI.

---

*انتهت الخطة — مخطط_إصلاح_المزامنة*
