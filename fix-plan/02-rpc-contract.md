# خطة توحيد عقد RPC بين تطبيق Flutter والباكند

**المخطط:** مخطط_توحيد_عقد_RPC (RPC Contract Unification Architect)
**التاريخ:** 2026-08-18
**النطاق:** عقد API الكامل بين `mobile/lib` و`debt-ledger-supabase/supabase` — أسماء الدوال، المعاملات، القيم المرجعة، idempotency، versioning، واختبارات العقد.
**المراجع المعتمدة:** `analysis-reports/07-mobile-data-layer.md`، `analysis-reports/08-api-contracts.md`، `analysis-reports/05-double-entry.md`، والكود الفعلي في `merchant_repository.dart`، `sync_engine.dart`، والترحيلات 0001/0002/0003/0006/0008/0010/0012.

---

## 0. ملخص القرارات المعمارية

| # | الحالة | القرار | الجهة المعدَّلة |
|---|---|---|---|
| 1 | `create_ledger_entry` (معاملات زائدة من العميل) | **توسيع الباكند** بمعاملات التصنيف/السداد/المرفق، وحذف `p_currency_code` من العميل (العملة تُشتق من المحل) | باكند + عميل |
| 2 | `reverse_ledger_entry` (`p_original_entry_id`) | **تعديل العميل** إلى `p_entry_id` | عميل فقط |
| 3 | `apply_customer_discount` (`p_currency_code` زائد) | **تعديل العميل** — حذف المعامل | عميل فقط |
| 4 | الأربعة `command_*` (نزاع/دعوة/كشف) | **تعديل العميل** إلى الأسماء العامة الموجودة فعلاً — لا دوال جديدة | عميل فقط |
| 5 | إضافة عميل | **دالة باكند جديدة** `create_business_customer` + ربط العميل بطابور المزامنة | باكند + عميل |
| 6 | الدعوة بالهاتف | **توسيع الباكند** بمعامل `p_phone` يُحلَّل إلى `user_id` داخلياً (مرحلة 1) | باكند + عميل |
| 7 | تعدد العملات (C-7) | **تثبيت عملة واحدة لكل محل** للإطلاق؛ تعدد العملات قرار مرحلة 2 بتصميم محاسبي كامل | قرار منتج |
| 8 | الترحيل 0012 المكسور | **إعادة كتابته**: الإبقاء على الأعمدة الخمسة فقط، وحذف الدالة والتريجر والجدول المكسورين | باكند |

---

## 1. جدول العقد الموحد (النسخة النهائية v1)

هذا الجدول هو **المرجع الوحيد الملزم** للطرفين. أي انحراف عنه يجب أن يكسر CI (انظر §5).

### 1.1 أوامر الكتابة (RPC عبر PostgREST)

| # | الدالة العامة النهائية | التوقيع النهائي (المعاملات بالترتيب) | القيمة المرجعة | المصدر الحالي | الحكم |
|---|---|---|---|---|---|
| 1 | `create_business` | `(p_name text, p_business_type text, p_currency_code varchar, p_country_code varchar default 'YE', p_city text default null, p_address text default null)` | `uuid` (business_id) | `0002:174-185` | بلا تغيير — على العميل استدعاؤها (خطة المصادقة) |
| 2 | **`create_business_customer`** (جديدة) | `(p_business_id uuid, p_local_display_name text, p_credit_limit numeric default null, p_default_due_days smallint default null, p_client_request_id uuid default gen_random_uuid())` | `uuid` (business_customer_id) | — | **جديدة** — انظر §3 |
| 3 | `add_business_customer` | `(p_business_id uuid, p_customer_id uuid, p_local_display_name text, p_credit_limit numeric default null, p_default_due_days smallint default null)` | `uuid` | `0002:226-234` | بلا تغيير — تُستخدم عند وجود `customer_id` معروف (ربط عميل مسجَّل) |
| 4 | **`create_ledger_entry`** (موسَّعة) | `(p_business_customer_id uuid, p_entry_type public.ledger_entry_type, p_amount numeric, p_description text, p_category text default 'goods', p_payment_method text default 'cash', p_reference_number text default null, p_bank_or_agent_name text default null, p_attachment_url text default null, p_occurred_at timestamptz default now(), p_due_date date default null, p_external_reference text default null, p_client_request_id uuid default gen_random_uuid(), p_source_device_id uuid default null)` | `uuid` (entry_id) | `0002:413-425` + `0010:346-376` | **توسيع باكند** — انظر §1.2-أ |
| 5 | `apply_customer_discount` | `(p_business_customer_id uuid, p_amount numeric, p_description text, p_occurred_at timestamptz default now(), p_client_request_id uuid default gen_random_uuid())` | `uuid` | `0010:404-408` | بلا تغيير — العميل يحذف `p_currency_code` |
| 6 | `reverse_ledger_entry` | `(p_entry_id uuid, p_reason text, p_client_request_id uuid default gen_random_uuid())` | `uuid` (reversal entry_id) | `0002:453-455` | بلا تغيير — العميل يصحح اسم المعامل |
| 7 | `confirm_ledger_entry` | `(p_entry_id uuid, p_device_id uuid default null)` | `uuid` | `0002:496-498` | بلا تغيير |
| 8 | `open_dispute` | `(p_entry_id uuid, p_reason public.dispute_reason, p_description text)` | `uuid` (dispute_id) | `0002:530-532` | بلا تغيير — تنبيه: قيم `p_reason` من العميل يجب أن تطابق enum `dispute_reason` السبع (`0001:24`) وليس القيم الوهمية في `dispute_model.dart:87-103` (ملاحظة L-1 في تقرير 08) |
| 9 | `add_dispute_message` | `(p_dispute_id uuid, p_message text, p_client_request_id uuid default null)` — المعامل الثالث يُضاف في مرحلة 1 | `uuid` (message_id) | `0002:563-565` | الاسم موجود؛ العميل يصحح الاسم فوراً، وidempotency في مرحلة 1 |
| 10 | `resolve_dispute` | `(p_dispute_id uuid, p_resolution public.dispute_current_status, p_resolution_note text, p_corrected_amount numeric default null, p_client_request_id uuid default null)` — الأخير يُضاف في مرحلة 1 | `uuid` | `0002:606-608` | العميل يصحح الاسم + `p_note`→`p_resolution_note` فوراً |
| 11 | `invite_business_member` | `(p_business_id uuid, p_target_user_id uuid default null, p_role public.business_role, p_expires_at timestamptz default (now()+interval '7 days'), p_phone text default null)` — `p_phone` يُضاف في مرحلة 1 | `uuid` (invite_id) | `0008:60-64` | فوراً: العميل يرسل `p_target_user_id`؛ مرحلة 1: دعم الهاتف |
| 12 | `respond_business_member_invite` | `(p_invite_id uuid, p_accept boolean)` | `void` | `0008:91-93` | بلا تغيير |
| 13 | `create_statement` | `(p_scope public.statement_scope, p_business_customer_id uuid default null, p_period_from timestamptz default (now()-interval '30 days'), p_period_to timestamptz default now())` | `uuid` (statement_id) | `0008:185-189` | بلا تغيير — العميل يصحح الاسم + `p_scope='business_customer'` |
| 14 | `request_customer_link` | `(p_business_customer_id uuid)` | `uuid` | `0002:263-265` | بلا تغيير — يُربط بواجهة التاجر (خطة شاشة العميل) |
| 15 | `respond_link_request` | `(p_request_id uuid, p_accept boolean)` | `void` | `0002:294-296` | بلا تغيير — يُربط بواجهة العميل |
| 16 | `post_manual_journal` / `close_accounting_period` | كما في `0010:438` و`0010:461` | `uuid` / `void` | `0010` | بلا تغيير — بلا واجهة في MVP (مقبول) |

**قاعدة ملزمة مشتقة من المنح:** كل الدوال أعلاه ممنوحة `execute` لـ `authenticated` (`0003:56-65`، `0008:207-209`، `0010:505-507`). الدوال في schema `private` **ليست** جزءاً من العقد ولا يجوز للعميل استدعاؤها إطلاقاً (غير مكشوفة عبر PostgREST أصلاً — `0003:67`).

### 1.2 قرارات الحسم لكل حالة انحراف (مع المبررات)

**أ. `create_ledger_entry` — توسيع الباكند لا تقليص العميل.**
- **الخيار 1 (تقليص العميل):** حذف `p_category, p_payment_method, p_reference_number, p_bank_or_agent_name, p_attachment_path` من الحمولة (`merchant_repository.dart:129-143`) والاكتفاء بالتوقيع الحالي ذي المعاملات التسعة. ميزته: صفر تغيير خلفي. عيبه: إلغاء ميزات منتج موجودة فعلاً في واجهة المستخدم (شاشة القيد `create_ledger_entry_sheet.dart` تجمع التصنيف وطريقة السداد)، والأعمدة الخمسة موجودة أصلاً في المخطط (`0012:5-10`).
- **الخيار 2 (توسيع الباكند) — الموصى به:** إضافة المعاملات الخمسة إلى `private.command_create_ledger_entry` (`0010:346`) وإلى الغلاف العام (`0002:413`)، مع الإبقاء على كل فحوص الصلاحيات وحد الائتمان والإيصالات الموجودة في 0010. المبرر: البيانات لها قيمة تجارية (تقارير حسب التصنيف/طريقة السداد)، والأعمدة جاهزة، والتوسيع additive لا يكسر أي عميل قديم.
- **استثناءان داخل القرار:**
  - `p_currency_code` **يُحذف من العميل ولا يُضاف للباكند**: التريجر `validate_ledger_entry_insert` (`0010:329-330`) يفرض عملة المحل الواحدة، وقبول عملة من العميل يكسر هذا الضابط ويفتح تضارب C-7. العملة تُشتق خلفياً من `businesses.currency_code` كما يفعل `0010:362` اليوم. واجهة العميل تقفل منتقي العملة على عملة المحل.
  - `p_attachment_path` (مسار محلي) يصبح `p_attachment_url` (مسار كائن Storage) ليطابق العمود الخلفي `attachment_url` (`0012:10`)، ويُرسل `null` حتى يُربط رفع المرفقات عبر `signed-document-upload` (مرحلة 1 — الخطوة 17).

**ب. `reverse_ledger_entry` — تعديل العميل.** اسم المعامل الخلفي `p_entry_id` (`0002:453`) متسق مع عائلة الدوال (`confirm_ledger_entry`, `open_dispute`) التي تسمي المعامل نفسه `p_entry_id`. توحيد العميل على الاسم السائد أرخص وأقل تشويشاً من إعادة تسمية ثلاث دوال خلفية.

**ج. `apply_customer_discount` — تعديل العميل.** نفس مبرر العملة في (أ): الخصم يجب أن يكون بعملة المحل حصراً، والدالة تشتقها (`0010:394`). لا مسوّغ لأي معامل عملة هنا.

**د. الدوال الأربع `command_*` — تعديل العميل، بلا أي دالة خلفية جديدة.**
- **الخيار 1 (أغلفة بأسماء `command_*`):** إضافة دوال عامة بديلة بالأسماء التي يتوقعها العميل. مرفوض: يضاعف سطح API (اسمان لكل عملية)، ويضاعف المنح والاختبارات، ويكسر قاعدة "مصدر حقيقة واحد"، وأسماء `command_*` محجوزة تقليدياً لـ schema `private` في هذا المشروع.
- **الخيار 2 (تصحيح العميل) — الموصى به:** الدوال العامة موجودة وممنوحة ومختبرة: `add_dispute_message` (`0002:563`)، `resolve_dispute` (`0002:606`)، `invite_business_member` (`0008:60`)، `create_statement` (`0008:185`). التصحيح أربعة أسطر في `merchant_repository.dart` (349، 367، 371، 422-426، 452-453).
- **ملاحظة حرجة مرتبطة:** حل نزاع `partially_accepted` على قيد `discount` يفشل دائماً في الباكند (تقرير 05، ملاحظة عالية 3: `0002:588` يستدعي `private.command_create_ledger_entry` بنوع `discount` والدالة ترفضه في `0010:356`). هذا إصلاح خلفي **شرط مسبق** لتشغيل مسار حل النزاع — مدرج كخطوة 8 ويملكه مخطط المحاسبة، لكن عقدنا يفترض إصلاحه.

**هـ. تعدد العملات — تثبيت عملة واحدة للإطلاق (حسم C-7).**
- الخياران: تفعيل تعدد العملات الآن (يتطلب إعادة تصميم `journal_entry_lines` بعملة لكل سطر + عملة أساسية + إصلاح ميزان المراجعة — تقرير 05 حرج 1)، أو تثبيت قيد العملة الواحدة (`0010:329-330`) وتأجيل الميزة.
- **التوصية: التثبيت والتأجيل.** الإطلاق التجاري بسوق يمني أولاً (YER)، وتعدد العملات تصميم مرحلة 2 مستقل. العقد v1 لا يحمل أي معامل عملة من العميل، ما يجعل إضافة `p_currency_code` الاختياري مستقبلاً تغييراً additive آمناً (انظر §4).

---

## 2. تصميم العمليات الأربع التي كان العميل يسميها `command_*`

الدوال العامة موجودة فعلاً؛ هذا القسم يثبت **العقد النهائي** لكل منها (توقيع + منطق + صلاحيات + idempotency) والفجوات الواجب سدها.

### 2.1 `add_dispute_message` — رسالة نزاع
- **التوقيع النهائي:** `(p_dispute_id uuid, p_message text, p_client_request_id uuid default null) returns uuid`.
- **المنطق الحالي (`0002:534-561`):** تحقق من وجود النزاع → صلاحية (عميل مالك النزاع أو عضو محل بأدوار owner/admin/accountant/collector) → إدراج الرسالة → قلب حالة النزاع (`awaiting_merchant`/`awaiting_customer`) → حدث + إشعار للطرف الآخر.
- **الصلاحيات:** كافية كما هي (`0002:542-545`).
- **فجوة idempotency:** لا تقبل `client_request_id` — إعادة إرسال من طابور أوفلاين ستكرر الرسالة. **الإصلاح (مرحلة 1):** معامل اختياري `p_client_request_id`؛ عند تمريره يُفحص `command_receipts` أولاً (النوع `'add_dispute_message'` مسموح أصلاً في قيد الـ check `0006:23`) ويُعاد `result_entity_id` المخزن، وعند النجاح يُكتب إيصال. عند غيابه (استدعاء أونلاين مباشر) يعمل كما اليوم.
- **قرار التشغيل أوفلاين:** رسائل النزاع تبقى **أونلاين فقط** في v1 (لا تدخل طابور المزامنة) — النزاع محادثة تفاعلية وليست قيداً مالياً، وتعقيد طابور لها غير مبرر للـ MVP. يُوثَّق ذلك في العقد ويُعرض للمستخدم زر إعادة محاولة عند الفشل بدل `false` الصامتة (`merchant_repository.dart:354-356`).

### 2.2 `resolve_dispute` — حل نزاع
- **التوقيع النهائي:** `(p_dispute_id uuid, p_resolution public.dispute_current_status, p_resolution_note text, p_corrected_amount numeric default null, p_client_request_id uuid default null) returns uuid`.
- **المنطق الحالي (`0002:567-604`):** صلاحية owner/admin/accountant → تحقق من قيمة resolution → عكس القيد عند accepted/partially_accepted → قيد مصحح عند partially_accepted → تحديث الحالة والأحداث والإشعارات.
- **الفجوات:** (1) خلل `partially_accepted` على قيود `discount` (تقرير 05 عالي 3) — **إصلاح إلزامي في مرحلة صفر** (الخطوة 8). (2) لا idempotency — نفس معالجة 2.1 (النوع `'resolve_dispute'` مسموح في `0006:23`). (3) الدالة لا تتحقق أن النزاع في حالة قابلة للحل؛ الإيصال يغطي إعادة الإرسال، لكن يُستحسن فحص `dispute_state.status not in ('accepted','partially_accepted','rejected','closed')` — يُسجَّل كتحسين مرحلة 1.
- **العميل:** يصحح الاسم و`p_note`→`p_resolution_note` فوراً.

### 2.3 `invite_business_member` — دعوة عضو
- **التوقيع النهائي:** `(p_business_id uuid, p_target_user_id uuid default null, p_role public.business_role, p_expires_at timestamptz default (now()+interval '7 days'), p_phone text default null) returns uuid` — يشترط أن يكون أحد `p_target_user_id`/`p_phone` غير خالٍ.
- **المنطق الحالي (`0008:33-58`):** منع دور owner ودعوة النفس → صلاحية owner/admin → منع دعوة عضو نشط → إلغاء الدعوات المعلقة السابقة → إدراج + إشعار.
- **idempotency:** طبيعية وكافية — الفهرس الفريد الجزئي `uq_pending_business_member_invite` (`0008:19-21`) + منطق إلغاء المعلّق السابق (`0008:50-51`) يجعلان إعادة الإرسال آمنة (دعوة جديدة تلغي القديمة). لا حاجة لـ `client_request_id`.
- **فجوة الهاتف (H-3):** واجهة الدعوة تجمع رقم هاتف/معرف (`invite_member_sheet.dart:114-132`) بينما الدالة تتطلب `uuid`. **التصميم (مرحلة 1):** معامل `p_phone text`؛ عند تمريره تُحلَّل الخلفية إلى `user_id` عبر استعلام `security definer` على `auth.users.phone` (لا يمكن للعميل فعل ذلك — جدول auth غير مكشوف). إن لم يوجد حساب: خطأ واضح «المستخدم غير مسجَّل» (MVP)، ودعوات SMS لغير المسجلين قرار مرحلة 2.
- **فوراً:** العميل يرسل `p_target_user_id` بالقيمة المدخلة بعد تحقق صيغة UUID في الواجهة.

### 2.4 `create_statement` — توليد كشف
- **التوقيع النهائي:** `(p_scope public.statement_scope, p_business_customer_id uuid default null, p_period_from timestamptz default (now()-interval '30 days'), p_period_to timestamptz default now()) returns uuid`.
- **المنطق الحالي (`0008:115-183`):** تحقق الفترة → صلاحية (عضو owner/admin/accountant أو عميل صاحب العلاقة) → لقطة مجاميع + بنود بأرصدة تراكمية + رمز تحقق فريد بإعادة محاولة عند التصادم.
- **الصلاحيات:** كافية (`0008:140-147`).
- **idempotency:** غير مطلوبة — كل استدعاء ينشئ لقطة جديدة **بالتصميم** (سجل تدقيق). العملية **أونلاين فقط** ولا تدخل طابور الأوفلاين؛ تكرار المستخدم للضغط ينتج كشفين وهذا مقبول وموثق. توليد الـ PDF والختم SHA-256 يتمان لاحقاً عبر Edge Function `generate-statement` ثم `service_attach_statement_document` (خطة Edge Functions — خارج نطاق هذه الخطة، لكن العقد لا يتغير).
- **العميل:** يصحح الاسم و`p_scope: 'business_customer'` (وليس `'customer'` — enum `statement_scope` في `0001:31`).

---

## 3. تصميم API إضافة العميل (سد الفجوة C-5 / ع-2)

### 3.1 المشكلة
`addCustomer` (`merchant_repository.dart:46-81`) محلي بحت: لا RPC، لا إدراج في `offline_mutations_queue`، ومعرّف `'cust-<uuid>'` غير صالح كـ UUID وليس له مقابل في `public.customers`. الدالة الخلفية الموجودة `add_business_customer` (`0002:226`) تشترط `p_customer_id` يشير إلى `public.customers` (`0001:126`)، وسجلات `customers` لا تُنشأ إلا عبر تريجر التسجيل `handle_new_auth_user` (`0002:132`) — أي للمستخدمين المسجلين فقط. عميل المتجر العادي (غير مسجَّل) لا مسار لإنشائه.

### 3.2 الخيارات
- **الخيار 1:** العميل ينشئ سجل `customers` مباشرة بـ INSERT. مرفوض: لا منحة INSERT على `customers` (`0003:47-53`)، ويخالف مبدأ API-only.
- **الخيار 2 — الموصى به:** دالة عامة جديدة `create_business_customer` بـ `security definer` تنشئ سجل `customers` (بـ `user_id = null`) وسجل `business_customers` **ذرّياً في معاملة واحدة**، مع idempotency كاملة. رقم الهاتف (PII) لا يمر عبر هذه الدالة — يلتقط لاحقاً عبر Edge Function `customer-directory`/`bootstrap-user-contact` التي تدير التشفير في `private.customer_contacts` (فصل PII عن API العام مبدأ قائم في `0001:80-81`).

### 3.3 مواصفة الدالة الجديدة (تُنشأ في ترحيل جديد `202608190013_api_contract_unification.sql`)

```sql
create or replace function public.create_business_customer(
  p_business_id uuid,
  p_local_display_name text,
  p_credit_limit numeric default null,
  p_default_due_days smallint default null,
  p_client_request_id uuid default gen_random_uuid()
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_customer_id uuid;
  v_bc_id uuid;
  v_existing_receipt public.command_receipts%rowtype;
begin
  -- 1) الصلاحية: نفس أدوار add_business_customer (0002:201)
  if not private.is_business_member(p_business_id, array['owner','admin','accountant','cashier']::public.business_role[]) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;

  -- 2) idempotency: إيصال سابق بنفس المفتاح؟
  select * into v_existing_receipt from public.command_receipts
   where idempotency_key = p_client_request_id and command_type = 'create_business_customer';
  if found then return v_existing_receipt.result_entity_id; end if;

  -- 3) إنشاء سجل العميل العام (غير مرتبط بحساب مستخدم)
  insert into public.customers(user_id) values (null) returning id into v_customer_id;

  -- 4) إنشاء العلاقة (تستعيد upsert المنطق الموجود في 0002:211-221)
  insert into public.business_customers(business_id, customer_id, local_display_name, credit_limit, default_due_days, link_status, created_by_user_id)
  values (p_business_id, v_customer_id, trim(p_local_display_name), p_credit_limit, p_default_due_days, 'unlinked', (select auth.uid()))
  returning id into v_bc_id;

  -- 5) إيصال
  insert into public.command_receipts(idempotency_key, user_id, command_type, status, result_entity_id, result)
  values (p_client_request_id, (select auth.uid()), 'create_business_customer', 'accepted', v_bc_id,
          jsonb_build_object('business_customer_id', v_bc_id, 'customer_id', v_customer_id))
  on conflict (idempotency_key) do nothing;

  return v_bc_id;
end $$;

grant execute on function public.create_business_customer(uuid,text,numeric,smallint,uuid) to authenticated;
```

**متطلب مصاحب إلزامي:** توسيع قيد الـ check في `command_receipts` (`0006:23`) ليشمل `'create_business_customer'` (ويُضاف أيضاً `'add_dispute_message'` و`'resolve_dispute'` موجودان أصلاً — لا تغيير لهما).

### 3.4 تغييرات العميل المقابلة
1. `addCustomer` يُدرج أمراً في الطابور: `command_type = 'create_business_customer'`، والحمولة `{p_business_id, p_local_display_name, p_credit_limit, p_default_due_days, p_client_request_id}` — داخل **نفس معاملة SQLite** مع الحفظ التفاؤلي (توسيع `saveLedgerEntryOptimistic` أو دالة موازية `saveCustomerOptimistic` في `app_database.dart`).
2. `sync_engine.dart:122-132`: فرع جديد يستدعي `rpc('create_business_customer', params: payload)`.
3. **تسوية المعرّفات (id reconciliation):** عند نجاح الإرسال، القيمة المرجعة `uuid` تستبدل المعرّف المحلي `'cust-*'` في `local_business_customers` **وفي كل قيود `local_ledger_entries` المعلقة** التي تشير إليه (وإلا فشل FK لكل قيد لاحق — ع-9). هذا شرط صحّة وليس تحسيناً.
4. ترتيب الطابور FIFO الحالي (`app_database.dart:483`) يضمن أن أمر إنشاء العميل يسبق قيوده شرط إدراجه أولاً — يُتحقق من ذلك في اختبار تكامل.

---

## 4. استراتيجية Versioning للعقد

### 4.1 المبدأ الحاكم: تطور additive فقط
PostgREST يطابق الدالة بالاسم + أسماء المعاملات (JSON named args)، والمعاملات ذات `default` اختيارية فعلياً. لذلك:
- **مسموح بلا إصدار جديد:** إضافة معامل جديد له `default` (العملاء القدامى لا يرسلونه فيعمل الافتراضي)؛ إضافة دالة جديدة؛ توسيع enum بقيمة جديدة لا يرسلها القدامى.
- **محظور بلا إصدار جديد:** إعادة تسمية معامل/دالة، حذف معامل، تغيير نوع، تشديد validation يرفض حمولات كانت مقبولة، تغيير دلالات القيمة المرجعة.
- **التغيير الكاسر** يتطلب دالة جديدة بلاحقة `_v2` (مثلاً `create_ledger_entry_v2`) مع إبقاء v1 تعمل **دورتي إصدار على الأقل** (نحو 8 أسابيع) ووسمها `deprecated` في سجل العقد، ثم إزالتها بعد انقضاء نافذة الدعم وتحقق تليمتري عدم الاستخدام.

### 4.2 آليات التثبيت
1. **سجل العقد (Contract Registry):** ملف `debt-ledger-supabase/docs/api-contract.md` **مولَّد آلياً** من قاعدة البيانات (انظر §5.2) — لا يُحرَّر يدوياً؛ نسخته الحالية v1.0.0.
2. **دالة نسخة:** `public.api_contract_version() returns text` تُرجع `'1.0.0'` — يستعلمها العميل عند بدء التشغيل ويسجلها في التليمتري لتشخيص انحراف النسخ في الدعم الفني.
3. **ثابت نسخة في العميل:** `RpcContract.contractVersion = '1.0.0'` في `mobile/lib/core/api/rpc_contract.dart` (ملف جديد — الخطوة 4)؛ عند تحديث العقد يُرفع الرقم ويُراجَع في نفس PR مع تغيير الباكند.
4. **CHANGELOG للعقد:** قسم مستقل في `debt-ledger-supabase/CHANGELOG.md` بعنوان `## API Contract` يوثق كل تغيير additive/kasir مع تاريخه ونافذة الإهلاك.

---

## 5. اختبارات العقد (Contract Tests) — منع تكرار الانحراف

السبب الجذري لكل كسور C-1..C-5: لا يوجد أي اختبار يربط حمولات العميل بتواقيع الباكند، والأخطاء تُبتلع صامتاً. أربع طبقات دفاع:

### 5.1 اختبارات pgTAP للتواقيع — `supabase/tests/database/004_api_contract.sql`
لكل دالة من الـ 16 في §1.1:
- `has_function('public', 'create_ledger_entry', array[...أسماء/أنواع المعاملات الدقيقة...])`
- `function_returns('public', 'create_ledger_entry', [...], 'uuid')`
- `function_lang_is` + تحقق أن الدالة ليست في schema `private`.
- اختبار سلبي: `isnt(has_function('public','command_add_dispute_message',...), true)` — يمنع عودة الأسماء الشبحية.
**معيار النجاح:** `pg_prove` أخضر؛ أي تغيير توقيع يكسر الاختبار فوراً.

### 5.2 بيان العقد (Contract Manifest) + بوابة CI
- سكربت `supabase/scripts/export_contract_manifest.sh` ينفذ استعلاماً على `pg_proc`/`information_schema` يصدّر JSON بكل دوال `public` الممنوحة لـ `authenticated`: الاسم، المعاملات (اسم/نوع/افتراضي)، نوع الإرجاع.
- الناتج يُقارن بملف ذهبي مودع `supabase/tests/contract/contract-manifest.json`.
- **بوابة CI:** أي PR يلمس `supabase/migrations/**` يجب أن يُحدّث الملف الذهبي في نفس PR، وإلا فشل. هذا يجعل كل تغيير عقد **مرئياً في المراجعة**.

### 5.3 اختبار حمولات Dart — `mobile/test/contract/rpc_payload_contract_test.dart`
- ملف مولَّد `mobile/lib/core/api/rpc_contract.dart` يعرّف لكل أمر: اسم الدالة + مجموعة مفاتيح الحمولة المسموحة (Set<String>) — يُولَّد من نفس `contract-manifest.json` (سكربت `mobile/tool/gen_rpc_contract.dart`).
- الاختبار يجزّئ `merchant_repository.dart`/`sync_engine.dart` فعلياً: يبني كل حمولة (`create_ledger_entry`، `apply_customer_discount`، ...) ويؤكد أن مفاتيحها **مساوية تماماً** (لا زيادة ولا نقصان في المعاملات الإلزامية) لمجموعة العقد.
- **قاعدة هيكلية:** كل استدعاءات `client.rpc` يجب أن تمر عبر `RpcContract` المركزي — يُفرض بـ custom lint أو اختبار grep يفشل عند أي `rpc('` حرفي خارج الملف المركزي. هذا يمنع تشتت الأسماء مجدداً.

### 5.4 اختبار تكامل دخاني (Smoke) — `supabase/tests/integration/rpc_smoke_test.dart`
بيئة `supabase start` محلية + fixtures (محل + عميل + عضوية): ينفذ كل أمر من أوامر الطابور الخمسة + الأربعة المصححة **بالحمولات الحرفية من العميل** ويؤكد نجاحها ووجود الإيصال في `command_receipts`. يعمل في CI ليلياً وعند كل تغيير عقد. هذا الاختبار كان سيكشف 100% من كسور C-1..C-5 في أول تشغيل.

---

## 6. خطوات التنفيذ المرقمة

> الاختصارات: **جهد** = يوم عمل شخص واحد (س = ساعات). الاعتماديات برقم الخطوة.

### [فوري — خلال 24 ساعة] (عميل فقط، بلا اعتمادية خلفية)

**الخطوة 1 — تصحيح معامل العكس.**
- الملف: `mobile/lib/features/merchant/data/merchant_repository.dart:260`.
- التغيير: `'p_original_entry_id'` → `'p_entry_id'`.
- التحقق: اختبار الحمولات (خطوة 5) أخضر + smoke يمر بعكس قيد.
- الاعتماديات: — | الجهد: 0.5 س.

**الخطوة 2 — حذف `p_currency_code` من حمولة الخصم.**
- الملف: `merchant_repository.dart:190-196`.
- التغيير: حذف السطر 194.
- التحقق: اختبار الحمولات + smoke للخصم.
- الاعتماديات: — | الجهد: 0.5 س.

**الخطوة 3 — تصحيح الاستدعاءات الأربعة `command_*`.**
- الملف: `merchant_repository.dart:349` → `add_dispute_message`؛ `:367,371` → `resolve_dispute` مع `p_resolution_note`؛ `:422-426` → `invite_business_member` مع `p_target_user_id` (مع تحقق UUID في `invite_member_sheet.dart:114-132`)؛ `:452-453` → `create_statement` مع `p_scope: 'business_customer'`.
- التحقق: smoke للأربعة + اختفاء `PGRST202` من السجلات.
- الاعتماديات: — | الجهد: 3 س.

**الخطوة 4 — تمركز أسماء RPC في `RpcContract`.**
- الملف الجديد: `mobile/lib/core/api/rpc_contract.dart`؛ تحديث `sync_engine.dart:122-132` و`merchant_repository.dart` لاستخدامه.
- التغيير: ثوابت أسماء الدوال + بناة الحمولات (payload builders) — مصدر واحد للأسماء والمفاتيح.
- التحقق: lint الـ grep (§5.3) أخضر؛ لا `rpc('` حرفي خارج الملف.
- الاعتماديات: 1-3 | الجهد: 4 س.

**الخطوة 5 — اختبار حمولات Dart الذهبي.**
- الملف الجديد: `mobile/test/contract/rpc_payload_contract_test.dart`.
- التحقق: `flutter test` أخضر؛ يفشل عند إضافة/حذف أي مفتاح حمولة.
- الاعتماديات: 4 | الجهد: 4 س.

### [مرحلة صفر — يحظر الإطلاق]

**الخطوة 6 — إعادة كتابة الترحيل 0012.**
- الملف: `debt-ledger-supabase/supabase/migrations/202608180012_multi_currency_and_categories.sql`.
- التغيير: الإبقاء فقط على الأعمدة الخمسة (`0012:5-10`)؛ **حذف**: جدول `customer_currency_balances` وسياساته (`:13-48`)، التريجر ودالته (`:51-111`)، والدالة `public.command_create_ledger_entry` (`:114-209`). المبرر: الترحيل لا يمكن أن يكون طُبق في أي بيئة (يفشل عند `:41`)، فإعادة الكتابة في المكان آمنة؛ تعدد العملات يُعاد تصميمه في مرحلة 2.
- التحقق: `supabase db reset` ينجح كاملاً؛ كل اختبارات pgTAP الحالية خضراء؛ بحث `has_business_permission|business_permission` في المخطط المنشور = صفر.
- الاعتماديات: — | الجهد: 1 يوم.

**الخطوة 7 — توسيع `create_ledger_entry` خلفياً.**
- ملف جديد: `supabase/migrations/202608190013_api_contract_unification.sql` — `create or replace` لكل من `private.command_create_ledger_entry` (نسخة `0010:346-376` + خمسة معاملات جديدة تُدرج في الأعمدة الخمسة) و`public.create_ledger_entry` (الغلاف بالتوقيع النهائي في §1.1-4).
- قيود: لا معامل عملة؛ الحفاظ على فحوص `is_business_member` وحد الائتمان والإيصال (`0010:359-373`)؛ قيم `p_category`/`p_payment_method` تُقيَّد بـ check بسيط (قوائم مسموحة) لمنع القمامة.
- التحقق: pgTAP جديد يثبت التوقيع + إدراج قيد بتصنيف/سداد وقراءته؛ اختبارات 003 الحالية تبقى خضراء.
- الاعتماديات: 6 | الجهد: 1 يوم.

**الخطوة 8 — إصلاح حل النزاع الجزئي على قيود الخصم.**
- الملف: نفس ترحيل 0013 — تعديل `private.command_resolve_dispute` (`0002:586-589`): عندما يكون `v_entry.entry_type='discount'` يُنشأ القيد المصحح عبر `private.command_apply_customer_discount` بدل `command_create_ledger_entry`.
- التحقق: pgTAP: نزاع `partially_accepted` على خصم ينجح ويولّد عكساً + قيداً مصححاً متوازنين.
- الاعتماديات: 6 | الجهد: 0.5 يوم. (بالتنسيق مع مخطط المحاسبة — المالك المحاسبي، مدرج هنا لأنه شرط لتشغيل عقد النزاع.)

**الخطوة 9 — دالة `create_business_customer` + توسيع إيصالات الأوامر.**
- الملف: ترحيل 0013 — الدالة بمواصفة §3.3 تنفيذاً حرفياً + تعديل قيد check في `command_receipts` (`0006:23`) لإضافة `'create_business_customer'`.
- التحقق: pgTAP: إنشاء عميل غير مسجَّل ينجح ذرّياً؛ إعادة الاستدعاء بنفس `p_client_request_id` تُرجع نفس `business_customer_id` بلا تكرار؛ غير العضو يُرفض بـ `42501`.
- الاعتماديات: 6 | الجهد: 1 يوم.

**الخطوة 10 — ربط `addCustomer` بالطابور + تسوية المعرّفات.**
- الملفات: `merchant_repository.dart:46-81`، `app_database.dart` (دالة `saveCustomerOptimistic` داخل معاملة SQLite واحدة)، `sync_engine.dart:122-132` (فرع `create_business_customer`)، ودالة reconciliation تستبدل `cust-*` بالـ uuid المرجع في جدولي العملاء والقيود المحليين.
- التحقق: اختبار تكامل: إضافة عميل أوفلاين → قيد عليه أوفلاين → اتصال → المزامنة تنشئ العميل ثم القيد بنجاح (FIFO)؛ لا سطر `cust-` متبقٍ بعد المزامنة.
- الاعتماديات: 4، 9 | الجهد: 2 يوم.

**الخطوة 11 — تحديث حمولة إنشاء القيد في العميل.**
- الملف: `merchant_repository.dart:129-143` — حذف `p_currency_code`، إعادة تسمية `p_attachment_path`→`p_attachment_url` (قيمة `null` مؤقتاً)، إضافة `p_source_device_id` من تسجيل الجهاز عند توفره.
- التحقق: اختبار الحمولات + smoke لقيد debt وpayment بكل الحقول.
- الاعتماديات: 4، 7 | الجهد: 3 س.

**الخطوة 12 — اختبارات pgTAP للعقد.**
- الملف الجديد: `supabase/tests/database/004_api_contract.sql` (§5.1 كاملاً، الـ 16 دالة).
- التحقق: `pg_prove` أخضر؛ كسر متعمد لتوقيع يُسقط الاختبار (تجربة سلبية).
- الاعتماديات: 7، 9 | الجهد: 1 يوم.

**الخطوة 13 — بيان العقد + بوابة CI.**
- ملفات جديدة: `supabase/scripts/export_contract_manifest.sh`، `supabase/tests/contract/contract-manifest.json`، خطوة CI (`.github/workflows` أو ما يعادلها) تفشل عند انحراف البيان.
- التحقق: PR تجريبي يغيّر معاملاً دون تحديث البيان → CI أحمر.
- الاعتماديات: 12 | الجهد: 1 يوم.

**الخطوة 14 — اختبار التكامل الدخاني الشامل.**
- الملف الجديد: `supabase/tests/integration/rpc_smoke_test.dart` (§5.4).
- التحقق: يمر على بيئة محلية نظيفة؛ يُدرج في CI الليلي.
- الاعتماديات: 7، 9، 10، 11 | الجهد: 1.5 يوم.

**الخطوة 15 — قفل منتقي العملة في الواجهة على عملة المحل.**
- الملفات: `customer_ledger_screen.dart:33-37,363-369`، `create_ledger_entry_sheet.dart:90`.
- التغيير: حذف خياري SAR/USD من واجهة v1 (أو تعطيلهما بوسم «قريباً») — تنفيذ قرار §1.2-هـ.
- التحقق: لا مسار UI يولّد قيداً بعملة ≠ عملة المحل.
- الاعتماديات: قرار المنتج (مؤكد في هذه الخطة) | الجهد: 2 س.

### [مرحلة 1 — تجريبي مغلق]

**الخطوة 16 — idempotency لأمرَي النزاع.**
- الملف: ترحيل جديد `...0014_dispute_command_idempotency.sql` — إضافة `p_client_request_id uuid default null` إلى `add_dispute_message` و`resolve_dispute` مع فحص/كتابة `command_receipts` (§2.1، §2.2) + فحص قابلية حالة النزاع للحل.
- التحقق: pgTAP: إعادة بنفس المفتاح لا تكرر رسالة/حلاً.
- الاعتماديات: 12 | الجهد: 1 يوم.

**الخطوة 17 — رفع المرفقات وربط `attachment_url`.**
- الملفات: `attachment_picker_widget.dart` + `merchant_repository.dart` — استدعاء Edge Function `signed-document-upload` ثم الرفع ثم `finalize-document-upload`، وتمرير المسار المرجع في `p_attachment_url`.
- التحقق: قيد بمرفق يظهر رابطه في `ledger_entries.attachment_url` ويُفتح من الكشف.
- الاعتماديات: 11 + خطة Edge Functions | الجهد: 2 يوم.

**الخطوة 18 — الدعوة بالهاتف.**
- الملفات: ترحيل جديد — توسيع `invite_business_member` بـ `p_phone` (§2.3)؛ `invite_member_sheet.dart` و`merchant_repository.dart:414-431` لإرسال الهاتف.
- التحقق: pgTAP للتحليل هاتف→user والرفض عند غياب الحساب؛ smoke من الواجهة.
- الاعتماديات: 12 | الجهد: 1 يوم.

**الخطوة 19 — تثبيت versioning.**
- ملفات جديدة: `public.api_contract_version()` (ترحيل صغير)، `RpcContract.contractVersion`، توليد `docs/api-contract.md` من البيان، قسم CHANGELOG.
- التحقق: العميل يسجل النسخة عند الإقلاع؛ الوثيقة المولدة تطابق §1.1.
- الاعتماديات: 13 | الجهد: 0.5 يوم.

### [مرحلة 2 — إطلاق تجاري]

**الخطوة 20 — تصميم تعدد العملات الكامل.**
- نطاق: عملة لكل سطر يومية + عملة أساسية للمحل + إعادة بناء `customer_currency_balances` بمرجعية `customers` الصحيحة + ميزان مراجعة بالعملة — يملكها مخطط المحاسبة؛ عقدنا يضيف حينها `p_currency_code` الاختياري (additive) لـ `create_ledger_entry`/`apply_customer_discount`.
- التحقق: مراجعة معمارية + pgTAP توازن متعدد العملات.
- الاعتماديات: إطلاق مرحلة 1 المستقر | الجهد: 5+ أيام (تقدير مبدئي — خطة مستقلة).

**الخطوة 21 — أول تمرين إهلاك (deprecation drill).**
- نطاق: توثيق نافذة دعم v1، تليمتري استخدام لكل دالة، وتجهيز قالب `_v2`.
- التحقق: لوحة تليمتري تعرض استدعاءات كل دالة بنسختها.
- الاعتماديات: 19 | الجهد: 1 يوم.

---

## 7. مصفوفة التغطية (كل ملاحظة → خطوة)

| الملاحظة المصدرية | الخطوة |
|---|---|
| C-2 / ح-1 (create_ledger_entry) | 7، 11 |
| C-3 (reverse) | 1 |
| C-4 (discount) | 2 |
| C-1 (الأربعة command_*) | 3 |
| H-2 (scope الكشف) | 3 |
| H-3 (دعوة بالهاتف) | 3 (فوري: user_id) + 18 (هاتف) |
| C-5 / ع-2 (إضافة عميل) | 9، 10 |
| C-6 / تقرير05-حرج1 (ترحيل 0012) | 6 |
| C-7 (تضارب العملات) | 15 + قرار §1.2-هـ (+20 لاحقاً) |
| تقرير05-عالي3 (partially_accepted على خصم) | 8 |
| ع-9 (تسوية المعرّفات) | 10 |
| L-1 (قيم dispute_reason) | توثيق في §1.1-8 + يُنفذ مع خطة شاشة العميل |
| H-5/ع-6 (إيصالات وحدود إعادة المحاولة) | 9، 16 (الإيصالات) — حدود المحاولة/Dead-Letter خارج نطاق العقد (خطة محرك المزامنة) |
| ع-7 (occurred_at من ساعة الجهاز) | خارج نطاق العقد (خطة الأمن) — العقد يبقي المعامل، والتحقق خلفي |

**خارج النطاق (يملكه مخططون آخرون):** قراءات C-11..C-14 و`profiles.upsert` (خطة طبقة البيانات)، سحب `ledger_entries` في المزامنة (خطة محرك المزامنة)، المصادقة وOTP (خطة الأمن)، ربط Edge Functions التسع (خطة Edge Functions).

---

## 8. مخاطر وافتراضات

1. **إعادة كتابة 0012 في المكان** تفترض أنه لم يُطبَّق في أي بيئة (مستحيل تقنياً لأنه يفشل) — يُتحقق من ذلك في أول اجتماع تنفيذ بمراجعة `supabase_migrations.schema_migrations` في كل بيئة؛ إن وُجد مطبقاً جزئياً يُستبدل بترحيل تصحيحي جديد.
2. الخطوة 8 تلامس منطقاً محاسبياً — يجب أن يراجعها مخطط المحاسبة قبل الدمج.
3. توسيع قيد check في `command_receipts` (خطوة 9) يتطلب `alter table ... drop constraint / add constraint` — آمن لأن الجدول إلحاقي (append-only).
4. `p_occurred_at` من العميل يبقى مقبولاً في v1؛ تشديده (انحراف ≤ 24 ساعة) تغيير كاسر محتمل يُجدول كـ v2 عبر مسار §4.

*انتهت الخطة — مخطط_توحيد_عقد_RPC*
