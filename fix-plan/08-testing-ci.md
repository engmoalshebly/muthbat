# خطة الاختبارات وخط أنابيب CI — نظام «مُثبَت / دفتر ديون»

**المؤلف:** مخطط_الاختبارات_CI (Testing & CI Strategy Architect)
**الحالة:** خطة تنفيذية — جاهزة للتسليم لفريق هندسي
**المدخلات:** `analysis-reports/10-tests-launch-readiness.md`، `final-audit-report.md` (النتائج العابرة X-1…X-4)، ملفات pgTAP الثلاثة في `debt-ledger-supabase/supabase/tests/database/`، `debt-ledger-supabase/README.md`، `debt-ledger-supabase/docs/rls-matrix.md`، `mobile/test/widget_test.dart`، `mobile/lib/core/sync/sync_engine.dart`، `mobile/lib/core/database/app_database.dart`، `mobile/pubspec.yaml`، `supabase/config.toml`.

---

## 0. ملخص تنفيذي

الوضع الراهن (موثق بالأسطر): **31 تأكيد pgTAP** على 3 ملفات تغطي المسار السعيد فقط، **صفر اختبارات سلبية لـ RLS** (`001_schema_contract.sql:11-13` يفحص `pg_policies` لا السلوك)، **صفر اختبارات للـ Edge Functions التسع**، **اختبار موبايل وحيد** (`mobile/test/widget_test.dart` — 15 سطراً) مقابل 53 ملف dart تشمل أخطر منطق في المنتج (`sync_engine.dart` — 221 سطراً، `app_database.dart` — 521 سطراً بلا أي اختبار)، و**لا CI إطلاقاً** (لا `.github/workflows` في كامل `D:\Dafter`).

هذه الخطة تبني 4 طبقات اختبار (قاعدة بيانات / Edge Functions / موبايل / E2E) فوق خط أنابيب GitHub Actions واحد ببوابات إلزامية، وتنتهي بتعريف «جاهز للإطلاق» قابل للقياس آلياً. **24 خطوة تنفيذية** موزعة: 3 فورية، 10 مرحلة صفر، 7 مرحلة 1، 4 مرحلة 2.

**قاعدة حاكمة:** في نظام مالي متعدد المستأجرين، اختبار «ماذا يُمنع» يسبق «ماذا يعمل». كل خلية «Denied» في `docs/rls-matrix.md` تتحول إلى اختبار pgTAP فعلي قبل أي إطلاق.

---

## 1. القرارات المعمارية المحسومة

### قرار 1 — إطار اختبارات RLS السلبية
- **الخيار أ:** توسيع الملفات الثلاثة الحالية بإضافة تأكيدات سلبية.
- **الخيار ب:** ملفات pgTAP جديدة مخصصة (`01x_*.sql`) مع وحدة مساعدة (helper) لمحاكاة المستخدمين.
- **المحسوم: الخيار ب.** الملفات الحالية نظيفة وحتمية ومركزة؛ خلط النفي مع الإثبات يصعّب قراءة الفشل في CI. الملفات الجديدة تعيد استخدام نمط `set local role authenticated` + `set_config('request.jwt.claim.sub', ...)` المثبت فعلياً في `002_core_workflow.sql:17-20`.

### قرار 2 — استراتيجية اختبار Edge Functions
- **الخيار أ:** `deno test` وحدة فقط (سريع، لكن المنطق الحرج متشابك مع `Deno.env` و`createClient` داخل `index.ts` مباشرة).
- **الخيار ب:** اختبارات تكامل فقط عبر `supabase functions serve` + HTTP (واقعي، لكن بطيء وهش).
- **المحسوم: هجين بطبقتين.** (1) إعادة هيكلة خفيفة: استخراج المنطق النقي (HMAC، AES-GCM، SHA-256، التحقق من المدخلات) إلى وحدات نقية في `supabase/functions/_shared/` قابلة للاستيراد بلا副作用، واختبارها بـ `deno test`. (2) اختبارات تكامل HTTP في CI ضد الستاك المحلي للدوال الحرجة (`verify-statement`، `generate-statement`، `finalize-document-upload`، العاملان). المبرر: الثغرة الحرجة IDOR في `generate-statement/index.ts:425,449-457` لا يكشفها اختبار وحدة — تتطلب استدعاء HTTP حقيقي بهوية مستخدم لا يملك الكشف.

### قرار 3 — إطار اختبار قاعدة الموبايل المحلية (sqflite)
- **الخيار أ:** `sqflite_common_ffi` (تشغيل SQLite على سطح المكتب في `flutter test`).
- **الخيار ب:** Mock كامل لقاعدة البيانات.
- **المحسوم: الخيار أ.** `app_database.dart` يحتوي SQL خام (`rawQuery` في `:507`) ومنطق طابور (`offline_mutations_queue` في `:177`) — الـ mock سيختبر الـ mock لا المنطق. `sqflite_common_ffi` يشغّل نفس SQL الفعلي في CI بلا جهاز.

### قرار 4 — Golden tests للموبايل
- **المحسوم: مؤجلة لمرحلة 2 وبنطاق ضيق (3 شاشات فقط).** التطبيق RTL بخطوط عربية (`google_fonts`) وتصميمه ما زال يتغير؛ golden tests واسعة الآن = ضجيج فشل مستمر. البديل المرحلتين صفر/1: widget tests سلوكية (وجود عناصر، تفاعلات) لا بصرية.

### قرار 5 — بوابة CI: متى يفشل الدمج؟
- **المحسوم:** يفشل الدمج عند: (1) فشل `supabase db lint`، (2) فشل أي اختبار pgTAP، (3) فشل `flutter analyze` بأي error (تحذيرات info مسموحة مؤقتاً حتى مرحلة 1)، (4) فشل أي اختبار Flutter، (5) فشل `deno test` أو اختبارات تكامل الدوال، (6) كشف `gitleaks` لأي سر. **لا** بوابة تغطية نسبية في مرحلة صفر (القاعدة صفر تقريباً — أي عتبة ستكون اعتباطية)؛ تُفرض عتبة التغطية ابتداءً من مرحلة 1 (§7).

---

## 2. مصفوفة الاختبارات المطلوبة (مرتبة بالأولوية)

الأعمدة: المعرف | الطبقة | السيناريو | المرجع في التقارير/الكود | المرحلة.

### 2.1 قاعدة البيانات — pgTAP سلبي (RLS وصلاحيات) — الأولوية القصوى

| المعرف | السيناريو | المرجع | المرحلة |
|---|---|---|---|
| DB-N01 | تاجر المحل B لا يقرأ `business_customers` للمحل A | `rls-matrix.md` صف «Other business = Denied»؛ `README.md:94` | صفر |
| DB-N02 | تاجر المحل B لا يقرأ `ledger_entries` للمحل A | `README.md:94`؛ `10-tests:§2.أ.1` | صفر |
| DB-N03 | عميل مرتبط بالمحل A لا يقرأ بيانات عميل آخر في نفس المحل | `README.md:95`؛ `rls-matrix.md` | صفر |
| DB-N04 | التاجر لا يقرأ الكشف الموحد للعميل (`customer_consolidated` statement) | `README.md:81,96`؛ `rls-matrix.md` آخر صف | صفر |
| DB-N05 | `anon` لا يقرأ أي جدول مكشوف (businesses/ledger_entries/business_customers) | `rls-matrix.md` عمود Anonymous | صفر |
| DB-N06 | عميل غير مرتبط (`link_status ≠ linked`) لا يصل للبيانات المالية | `10-tests:§2.ب.9`؛ `First-version.md` قاعدة الربط | صفر |
| DB-N07 | `cashier` لا يستطيع عكس قيد (`reverse_ledger_entry`) — دوره إنشاء فقط | `rls-matrix.md` «Role permissions»؛ `10-tests:§2.ب.9` | صفر |
| DB-N08 | `collector`/`viewer` لا يستطيعان `create_ledger_entry` | `rls-matrix.md` | صفر |
| DB-N09 | التاجر لا يستطيع `confirm_ledger_entry` نيابة عن العميل | `README.md:101`؛ `First-version.md:1011` قاعدة 10 | صفر |
| DB-N10 | العميل لا يستطيع `resolve_dispute` | `rls-matrix.md` | صفر |
| DB-N11 | دعوة مرفوضة (`respond_business_member_invite(..., false)`) لا تنشئ صفاً في `business_members` | `10-tests:§2.ب.9` | صفر |
| DB-N12 | مستخدم غير عضو لا يستطيع استدعاء أي RPC مالي على محل لا ينتمي إليه | `03-security-rls.md`؛ نمط فحص `is_business_member` | صفر |

### 2.2 قاعدة البيانات — ثوابت مالية (pgTAP)

| المعرف | السيناريو | المرجع | المرحلة |
|---|---|---|---|
| DB-I01 | `UPDATE` على `ledger_entries` يُرفض | `README.md:98`؛ `10-tests:§2.ب.6` | صفر |
| DB-I02 | `DELETE` على `ledger_entries` يُرفض | `README.md:98` | صفر |
| DB-I03 | القيد العكسي لا يمكن عكسه | `README.md:99` | صفر |
| DB-I04 | مبلغ صفر أو سالب يُرفض في `create_ledger_entry` | `First-version.md:1003` قاعدة 8؛ `10-tests:§2.ج.10` | صفر |
| DB-I05 | عملة القيد ≠ عملة المحل تُرفض (حارس `validate_ledger_entry_insert`) | `First-version.md:1007` قاعدة 9؛ `202608140010:329-330` | صفر |
| DB-I06 | **سياسة الدفع الزائد المحسومة:** بعد حسم القرار المعماري (منع أم رصيد دائن — تناقض `README.md:100` مقابل `003_double_entry_accounting.sql:33,47-58`)، اختبار يثبت السلوك المختار ويمنع الآخر | `10-tests:§2.ب.7` | صفر (بعد قرار السياسة) |
| DB-I07 | لا يمكن فتح اعتراض ثانٍ مفتوح على نفس القيد | `README.md:102`؛ `First-version.md:782` | 1 |
| DB-I08 | الاعتراض لا يُعدَّل ولا يُحذف | `First-version.md:777-779` | 1 |
| DB-I09 | سيناريو رفض الاعتراض (`rejected`) وطلب معلومات إضافية | `10-tests:§2.ب.8` | 1 |
| DB-I10 | `apply_customer_discount`: خصم لعميل غير مرتبط يُرفض؛ خصم أكبر من الرصيد (حسب السياسة المحسومة) | `10-tests:§2.ج.10` | 1 |
| DB-I11 | **تزامن:** جلستان متوازيتان بنفس `client_request_id` → قيد واحد فقط (عبر `pg_sleep` + جلستين، أو اختبار تكامل CI بجلسات psql متوازية) | `First-version.md:1536`؛ `10-tests:§2.ب.5` | 1 |
| DB-I12 | تزامن: تأكيد ونزاع متزامنان على نفس القيد → حالة نهائية متسقة واحدة | `10-tests:§2.ب.5` | 1 |
| DB-I13 | **اختبار انحدار X-1:** تطبيق كل الترحيلات من الصفر على قاعدة فارغة ينجح (يكشف كسر 0012: سياسة `customer_currency_balances_select_member` المستدعية لدالة غير موجودة `0012:38-43`، وتريجر `direction='in'` مقابل enum `('debit','credit')` `0012:59`) | `final-audit-report.md:51-56` | فوري (يُغطى بخطوة CI نفسها) |
| DB-I14 | اختبار انحدار: تريجر تحديث الأرصدة لا يعطّل إدراج قيد عادي (خطأ `22P02` المكتشف) | `final-audit-report.md:52` | صفر |
| DB-I15 | توازن ميزان المراجعة بعد سيناريو متعدد العملات (بعد إصلاح 0012): لا جمع لعملتين في حساب واحد | `05-double-entry.md`؛ `final-audit-report.md:160` | 1 |

### 2.3 Edge Functions

| المعرف | السيناريو | المرجع | المرحلة |
|---|---|---|---|
| EF-U01 | وحدة: HMAC للهاتف حتمي ومتسق (نفس المدخل → نفس البصمة) | `bootstrap-user-contact`/`customer-directory`؛ `10-tests:§2.أ.2` | صفر |
| EF-U02 | وحدة: AES-GCM تشفير/فك تشفير رحلة ذهاب وعودة (round-trip) | `bootstrap-user-contact` | صفر |
| EF-U03 | وحدة: التحقق من بصمة SHA-256 للمرفق (مطابقة/عدم مطابقة) | `finalize-document-upload` | صفر |
| EF-I01 | تكامل: `verify-statement` برمز صحيح ينجح وبرمز خاطئ يفشل — بلا JWT (`config.toml:78-79`) | `10-tests:§2.ج.11` | صفر |
| EF-I02 | تكامل: **انحدار IDOR** — مستخدم مصادق لا يملك الكشف يمرر `statementId` جاهزاً لـ `generate-statement` → 403 (يكشف الثغرة في `index.ts:425,449-457`) | `final-audit-report.md:149`؛ `04-edge-functions.md` | صفر |
| EF-I03 | تكامل: استدعاء `process-notification-outbox` و`process-automation-rules` **بدون** `WORKER_SECRET` → 401 | `config.toml:81-85`؛ `10-tests:§4.22` | صفر |
| EF-I04 | تكامل: `customer-directory` لا يسرّب وجود رقم (استجابة متطابقة لرقم موجود/غير موجود) | `10-tests:§2.أ.2` (منع التعداد) | 1 |
| EF-I05 | تكامل: `finalize-document-upload` يرفض ملفاً ببصمة غير مطابقة أو حجم > 10MiB (`config.toml:37`) | `10-tests:§2.أ.2` | 1 |
| EF-I06 | تكامل: **انحدار العامل المكسور** — `process-automation-rules` يدرج في `reminders` بالأعمدة الفعلية (`sent_by_user_id`, `message_snapshot` — `0001:326-338`) ويمر عبر `enqueue_notification` | `final-audit-report.md:204`؛ `09-docs-vs-implementation.md` | 1 |
| EF-I07 | تكامل: `send-whatsapp-otp` يفشل صراحة عند غياب متغيرات البيئة (بعد إزالة الأسرار الصلبة من `index.ts:4-5`) | `10-tests:§4.18` | صفر (بعد تدوير السر) |

### 2.4 الموبايل

| المعرف | السيناريو | المرجع | المرحلة |
|---|---|---|---|
| MOB-U01 | وحدة: `AppDatabase` — إدراج mutation في `offline_mutations_queue` واسترجاعه بالترتيب | `app_database.dart:177,464-518` | صفر |
| MOB-U02 | وحدة: عدّاد `getPendingMutationsCount` يعكس الإدراج/الحذف | `app_database.dart:507` | صفر |
| MOB-U03 | وحدة: `SyncEngine` — عدم المعالجة المزدوجة (`_isProcessing` guard في `sync_engine.dart:77-80`) | `10-tests:§2.أ.3` | صفر |
| MOB-U04 | وحدة: كل mutation صادر يحمل `client_request_id` ثابتاً عبر إعادة المحاولة (idempotency من طرف العميل) | `README.md:87-88`؛ `sync_engine.dart:123` | صفر |
| MOB-U05 | وحدة: **انحدار X-3** — جسم الطلب المبني في `merchant_repository.dart:129-143` يطابق توقيع RPC المنشور (اختبار عقد: أسماء المعاملات الـ 12 مقابل التوقيع) | `final-audit-report.md:77-78`؛ `08-api-contracts.md` | صفر |
| MOB-U06 | وحدة: حسابات العرض — تنسيق المبالغ والعملة واتجاه الرصيد (مدين/دائن) | `06-multi-currency.md` | 1 |
| MOB-W01 | widget: شاشة التاجر تعرض الرصيد من الـ repository (mock) لا قيمة ثابتة | `merchant_home_screen.dart` | 1 |
| MOB-W02 | widget: **انحدار الشاشة الوهمية** — `customer_home_screen.dart` لا تعرض `'450,000 ر.ي'` الثابت وزر التأكيد يستدعي الـ controller فعلاً (`:94,181-195,264-272`) | `final-audit-report.md:193` | صفر |
| MOB-W03 | widget: حالات طابور الأوفلاين (شارة «قيد المزامنة» تظهر عند pendingCount > 0) | `sync_engine.dart` SyncProgress | 1 |
| MOB-G01 | golden: 3 شاشات مرجعية (splash، merchant home، customer ledger) بعد تثبيت التصميم | قرار 4 | 2 |
| MOB-E01 | E2E (`integration_test`): تاجر ينشئ ديناً أوفلاين → يتصل → يظهر القيد مرة واحدة في الباكند | `First-version.md:1536` | 2 |
| MOB-E02 | E2E: مسار OTP كامل (بعد حسم المزود الإنتاجي) | `10-tests:§4.19` | 2 |

### 2.5 أمان وسلسلة إمداد

| المعرف | السيناريو | المرجع | المرحلة |
|---|---|---|---|
| SEC-01 | فحص أسرار `gitleaks` على كامل التاريخ والـ PRs (يكشف نمط `owa_k1_...` في `send-whatsapp-otp/index.ts:4-5`) | `10-tests:§6.5` | فوري |
| SEC-02 | اختبار اختراق يدوي موثق: storage object بدون تفويض metadata | `README.md:103` | 1 |
| SEC-03 | تأكيد عدم وجود مفاتيح في كود العميل (`supabase_config.dart:8-13` يجب ألا يحمل service key أبداً — فحص CI نصي) | `final-audit-report.md:182` | صفر |

---

## 3. بنية اختبارات pgTAP السلبية لـ RLS (تفصيل تنفيذي)

### 3.1 هيكل الملفات الجديدة

```
debt-ledger-supabase/supabase/tests/database/
  001_schema_contract.sql            (موجود — يبقى كما هو)
  002_core_workflow.sql              (موجود)
  003_double_entry_accounting.sql    (موجود)
  010_rls_tenant_isolation.sql       (جديد — DB-N01..N05)
  011_rls_role_permissions.sql       (جديد — DB-N06..N12)
  012_ledger_immutability.sql        (جديد — DB-I01..I06)
  013_dispute_lifecycle.sql          (جديد — DB-I07..I09)
  014_concurrency.sql                (جديد — DB-I11..I12، مرحلة 1)
```

### 3.2 نمط الاختبار السلبي (قالب إلزامي)

كل اختبار نفي يتبع قالباً واحداً: **بناء مستأجرين A وB في نفس الملف**، ثم تبديل الهوية عبر `set_config('request.jwt.claim.sub', ...)`، ثم تأكيد أن الاستعلام يرجع **صفر صفوف** (للقراءة) أو يرفع **خطأ** (للكتابة عبر `throws_ok`).

### 3.3 مثال فعلي — `010_rls_tenant_isolation.sql` (مقتطفات جاهزة للتنفيذ)

```sql
begin;
select plan(6);

-- مستأجر A: مالك + عميل مرتبط (نفس نمط 002_core_workflow.sql:5-15)
insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
  raw_app_meta_data,raw_user_meta_data,created_at,updated_at) values
  ('00000000-0000-0000-0000-000000000000','a1111111-1111-1111-1111-111111111111','authenticated','authenticated','tenantA-owner@example.test','x',now(),'{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,now(),now()),
  ('00000000-0000-0000-0000-000000000000','a2222222-2222-2222-2222-222222222222','authenticated','authenticated','tenantA-customer@example.test','x',now(),'{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,now(),now()),
  ('00000000-0000-0000-0000-000000000000','b1111111-1111-1111-1111-111111111111','authenticated','authenticated','tenantB-owner@example.test','x',now(),'{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,now(),now());

select set_config('test.customerA_id',(select id::text from public.customers where user_id='a2222222-2222-2222-2222-222222222222'),true);

set local role authenticated;

-- المالك A يبني محله وعميله وقيداً مالياً
select set_config('request.jwt.claim.sub','a1111111-1111-1111-1111-111111111111',true);
select set_config('test.bizA',public.create_business('Tenant A Store','retail','YER')::text,true);
select set_config('test.bcA',public.add_business_customer(current_setting('test.bizA')::uuid,current_setting('test.customerA_id')::uuid,'Customer A',null)::text,true);
select set_config('test.linkA',public.request_customer_link(current_setting('test.bcA')::uuid)::text,true);
select set_config('request.jwt.claim.sub','a2222222-2222-2222-2222-222222222222',true);
select public.respond_link_request(current_setting('test.linkA')::uuid,true);
select set_config('request.jwt.claim.sub','a1111111-1111-1111-1111-111111111111',true);
perform public.create_ledger_entry(current_setting('test.bcA')::uuid,'debt',500,'Tenant A invoice',now(),null,null,'a3333333-3333-3333-3333-333333333333');

-- المالك B يبني محله ثم يحاول التجسس على A
select set_config('request.jwt.claim.sub','b1111111-1111-1111-1111-111111111111',true);
select set_config('test.bizB',public.create_business('Tenant B Store','retail','YER')::text,true);

-- DB-N01: عزل عملاء المستأجر
select is(
  (select count(*)::integer from public.business_customers where business_id=current_setting('test.bizA')::uuid),
  0, 'DB-N01: merchant B cannot read tenant A business_customers'
);

-- DB-N02: عزل القيود المالية
select is(
  (select count(*)::integer from public.ledger_entries le
     join public.business_customers bc on bc.id=le.business_customer_id
     where bc.business_id=current_setting('test.bizA')::uuid),
  0, 'DB-N02: merchant B cannot read tenant A ledger_entries'
);

-- DB-N05: المجهول لا يرى شيئاً
set local role anon;
select is(
  (select count(*)::integer from public.ledger_entries),
  0, 'DB-N05: anonymous role reads zero ledger rows'
);
set local role authenticated;

-- العميل A نفسه يرى قيده (تأكيد إيجابي مرافق — يمنع اختباراً ناجحاً زائفاً بسبب RLS مكسور يخفي كل شيء)
select set_config('request.jwt.claim.sub','a2222222-2222-2222-2222-222222222222',true);
select is(
  (select count(*)::integer from public.ledger_entries le
     join public.business_customers bc on bc.id=le.business_customer_id
     where bc.business_id=current_setting('test.bizA')::uuid),
  1, 'sanity: linked customer A still sees own entry (RLS not over-blocking)'
);

select * from finish();
rollback;
```

**قاعدة تصميم مهمة (موضحة في آخر تأكيد أعلاه):** كل ملف نفي يتضمن تأكيداً إيجابياً مرافقاً (sanity check) — وإلا فإن سياسة RLS مكسورة تخفي كل شيء ستجعل اختبارات النفي «ناجحة» زائفاً.

### 3.4 مثال — عزل عميل/عميل ومنع كشف التاجر الموحد (في `010` أيضاً)

```sql
-- DB-N04: التاجر لا يرى الكشف الموحد للعميل
-- (العميل A ينشئ كشفاً موحداً لنفسه، ثم يحاول المالك A قراءته)
select set_config('request.jwt.claim.sub','a2222222-2222-2222-2222-222222222222',true);
select set_config('test.consolidated',public.create_statement('customer_consolidated',current_setting('test.customerA_id')::uuid,now()-interval '30 days',now())::text,true);
select set_config('request.jwt.claim.sub','a1111111-1111-1111-1111-111111111111',true);
select is(
  (select count(*)::integer from public.statements where id=current_setting('test.consolidated')::uuid),
  0, 'DB-N04: merchant never reads the customer consolidated statement'
);
```

### 3.5 مثال — صلاحيات الأدوار السلبية — `011_rls_role_permissions.sql`

```sql
-- بعد قبول دعوة cashier (نمط 002:81-91)، ينتحل الـ cashier ويحاول العكس:
select set_config('request.jwt.claim.sub','<cashier_user_id>',true);
select throws_ok(
  format('select public.reverse_ledger_entry(%L::uuid, %L)', '<entry_id>', '<new_client_request_id>'),
  'P0001', null, -- أو رمز الخطأ الفعلي المرفوع من فحص الدور
  'DB-N07: cashier cannot reverse a ledger entry'
);
-- التاجر يحاول التأكيد نيابة عن العميل:
select set_config('request.jwt.claim.sub','<merchant_user_id>',true);
select throws_ok(
  format('select public.confirm_ledger_entry(%L::uuid)','<entry_id>'),
  'P0001', null,
  'DB-N09: merchant cannot confirm on behalf of the customer'
);
```

> ملاحظة تنفيذية: يجب ضبط رمز الخطأ المتوقع (`P0001` للـ `raise exception` العام أو `42501` insufficient_privilege) من الكود الفعلي في `202607120002_functions_and_triggers.sql` أثناء التنفيذ، وتوثيقه في ترويسة الملف.

### 3.6 مثال — عدم القابلية للتعديل — `012_ledger_immutability.sql`

```sql
-- DB-I01/DB-I02: كتابة مباشرة على الجدول ممنوعة (revoke + تريجر)
select throws_ok(
  format('update public.ledger_entries set amount=999 where id=%L::uuid','<entry_id>'),
  '42501', null, 'DB-I01: UPDATE on ledger_entries is rejected'
);
select throws_ok(
  format('delete from public.ledger_entries where id=%L::uuid','<entry_id>'),
  '42501', null, 'DB-I02: DELETE on ledger_entries is rejected'
);
-- DB-I04: قيود المبلغ
select throws_ok(
  'select public.create_ledger_entry(''<bc>''::uuid,''debt'',0,''zero'',now(),null,null,''a4444444-4444-4444-4444-444444444444''::uuid)',
  null, null, 'DB-I04: zero amount is rejected'
);
```

---

## 4. استراتيجية اختبار Edge Functions (تفصيل)

### 4.1 إعادة الهيكلة التمهيدية (شرط مسبق)
- استخراج إلى `supabase/functions/_shared/`: `phone_crypto.ts` (HMAC + AES-GCM)، `file_integrity.ts` (SHA-256)، `http_guard.ts` (التحقق من `WORKER_SECRET` وهوية المتصل). الاستيراد النسبي معتمد في Deno ولا يغيّر سلوك النشر.
- حذف القيم الافتراضية الصلبة من `send-whatsapp-otp/index.ts:4-5` والفشل الصريح `throw new Error('OPENWA_API_KEY is required')` — شرط مسبق لـ EF-I07 (يتولاه مخطط الأمن؛ نختبره هنا).

### 4.2 اختبارات الوحدة (Deno test)
- موقعها: `supabase/functions/_shared/*_test.ts` و`supabase/functions/<fn>/index_test.ts` للمنطق النقي.
- تشغيل: `deno test --allow-env supabase/functions/` (لا `--allow-net` في اختبارات الوحدة — أي استيراد يسحب شبكة يفشل، وهذا مقصود).
- تغطي: EF-U01..U03 + دوال التحقق من المدخلات لكل دالة.

### 4.3 اختبارات التكامل (HTTP ضد الستاك المحلي)
- موقعها: `supabase/functions/tests/integration/*.test.ts` (Deno test مع `--allow-net --allow-env`).
- في CI: `supabase start` ثم `supabase functions serve --no-verify-jwt` (أو بالإعدادات الفعلية من `config.toml:63-85`) ثم تشغيل الجناح.
- لاختبارات الهوية (EF-I02): توليد JWT اختبار محلياً بمفتاح الستاك المحلي المعروف (`supabase status -o env` يوفر `ANON_KEY` و`JWT_SECRET` المحليين) وتمريره في ترويسة `Authorization`.
- تغطي: EF-I01..I07.

---

## 5. استراتيجية اختبار الموبايل (تفصيل)

### 5.1 تعديلات `pubspec.yaml` (dev_dependencies)
إضافة: `sqflite_common_ffi` (قرار 3)، `mocktail` (للـ repository/controller mocks — أخف من mockito بلا code generation)، `integration_test` (sdk، مرحلة 2)، `fake_async` (لاختبار `Timer.periodic` في `sync_engine.dart:53-56`).

### 5.2 هيكل `mobile/test/`
```
test/
  widget_test.dart                     (موجود — يُحدَّث لاحقاً)
  core/database/app_database_test.dart (MOB-U01..U02)
  core/sync/sync_engine_test.dart      (MOB-U03..U04)
  features/merchant/data/merchant_repository_contract_test.dart (MOB-U05)
  features/merchant/presentation/merchant_home_test.dart        (MOB-W01)
  features/customer/presentation/customer_home_test.dart        (MOB-W02)
integration_test/                      (مرحلة 2 — MOB-E01..E02)
```

### 5.3 نقاط تقنية
- `AppDatabase` singleton (`AppDatabase.instance`) يحتاج نقطة حقن: إضافة منشئ اختباري `@visibleForTesting AppDatabase.forTesting(DatabaseExecutor db)` أو مصنع قابل للحقن — تعديل طفيف في `app_database.dart` يبرره الاختبار. معيار القبول: الاختبار يعمل بـ `databaseFactoryFfi` في ذاكرة.
- `SyncEngine` يعتمد `Connectivity()` و`SupabaseConfig` مباشرة (`sync_engine.dart:1-6`) — يحتاج حقن `Connectivity` وعميل RPC عبر منشئ اختباري؛ بدونه MOB-U03/U04 غير قابلة للاختبار. هذا تعديل تصميمي صغير موثق كخطوة مستقلة (الخطوة 14).
- MOB-U05 (عقد RPC): اختبار وحدة يقرأ توقيعات RPC من ملف عقد ثابت `test/contracts/rpc_signatures.json` مستخرج من `docs/api-reference-and-operational-flow.md`، ويؤكد أن أسماء المعاملات المرسلة في `merchant_repository.dart` ⊆ التوقيع المنشور. **يكشف X-3 فوراً** (12 معاملاً مرسلة مقابل 9 مقبولة — `final-audit-report.md:77`).

---

## 6. خط أنابيب CI — GitHub Actions

### 6.1 المراحل والبوابات

| المرحلة | المهمة | بوابة (يفشل الدمج عند) |
|---|---|---|
| 1. Secrets scan | gitleaks | أي سر مكتشف |
| 2. Backend lint+test | `supabase db lint --local` + `supabase test db` | أي lint error أو فشل pgTAP |
| 3. Edge unit | `deno test` (وحدة) | أي فشل |
| 4. Edge integration | functions serve + جناح HTTP | أي فشل |
| 5. Flutter analyze+test | `flutter analyze --no-fatal-infos` + `flutter test --coverage` | أي error أو فشل اختبار |
| 6. Migration fresh-apply | `supabase db reset` على قاعدة فارغة | فشل تطبيق أي ترحيل (يكشف X-1) |

المراحل 2–5 تعمل بالتوازي بعد المرحلة 1؛ المرحلة 6 تابعة لـ 2 (تعيد استخدام الستاك).

### 6.2 ملف YAML توضيحي — `.github/workflows/ci.yml` (يُنشأ في جذر `D:\Dafter` أو جذر المستودع الموحد)

```yaml
name: ci
on:
  pull_request:
  push:
    branches: [main]

concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

jobs:
  secrets:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - uses: gitleaks/gitleaks-action@v2
        env: { GITLEAKS_ENABLE_COMMENTS: 'true' }

  supabase-db:
    needs: secrets
    runs-on: ubuntu-latest
    defaults:
      run: { working-directory: debt-ledger-supabase }
    steps:
      - uses: actions/checkout@v4
      - uses: supabase/setup-cli@v1
        with: { version: latest }
      - name: Start local stack (fresh DB — migration regression gate)
        run: supabase start --yes
      - name: Lint migrations
        run: supabase db lint --local
      - name: Run pgTAP suite
        run: supabase test db
      - name: Fresh reset (X-1 regression — 0012 must apply cleanly)
        run: supabase db reset --yes

  edge-unit:
    needs: secrets
    runs-on: ubuntu-latest
    defaults:
      run: { working-directory: debt-ledger-supabase }
    steps:
      - uses: actions/checkout@v4
      - uses: denoland/setup-deno@v2
      - run: deno test --allow-env supabase/functions/

  edge-integration:
    needs: secrets
    runs-on: ubuntu-latest
    defaults:
      run: { working-directory: debt-ledger-supabase }
    steps:
      - uses: actions/checkout@v4
      - uses: supabase/setup-cli@v1
      - uses: denoland/setup-deno@v2
      - run: supabase start --yes
      - name: Serve functions
        run: supabase functions serve --no-verify-jwt > functions.log 2>&1 &
      - name: Run HTTP integration suite
        run: deno test --allow-net --allow-env supabase/functions/tests/integration/

  flutter:
    needs: secrets
    runs-on: ubuntu-latest
    defaults:
      run: { working-directory: mobile }
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with: { channel: stable, cache: true }
      - run: flutter pub get
      - run: flutter analyze --no-fatal-infos
      - run: flutter test --coverage
      - name: Coverage gate (phase 1+)
        if: github.ref == 'refs/heads/main'
        run: |
          TOTAL=$(grep -c '^DA:' coverage/lcov.info || true)
          HIT=$(grep -c '^DA:.*,[1-9]' coverage/lcov.info || true)
          echo "lines=$TOTAL hit=$HIT"
          # يُفعَّل العتبة (70% على lib/core) ابتداءً من مرحلة 1 — انظر §7

  client-secrets-guard:
    needs: secrets
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: SEC-03 — no service-role key in client code
        run: |
          ! grep -rEi 'service_role|eyJhbGciOi.*\.eyJ.*service_role' mobile/lib/ \
            || (echo 'service key leaked into client' && exit 1)
```

**ملاحظات تنفيذية:** منافذ الستاك المحلي معزولة (`config.toml:5,11,27` — 5532x) فلا تتصادم مهام متوازية على نفس العامل؛ `concurrency` يلغي تشغيلات PR القديمة؛ كل المراحل `needs: secrets` لمنع هدر الدقائق عند وجود سر مسرب.

---

## 7. تعريف «الجاهز للإطلاق» القابل للقياس

يُعتبر النظام جاهزاً لمرحلة ما **فقط** عند تحقق كل معاييرها آلياً في CI على `main`:

### جاهزية «مرحلة صفر — يحظر الإطلاق قبلها»
1. CI أخضر على `main`: المراحل الست في §6.1 كلها ناجحة.
2. pgTAP: ≥ 60 تأكيداً ناجحاً (الحالي 31 + DB-N01..N12 + DB-I01..I06 + DB-I14 ≈ 60)، **منها ≥ 20 تأكيداً سلبياً** (يفشل بنجاح زائف إن اختفى — يُتحقق يدوياً مرة بكسر سياسة عمداً على فرع تجريبي).
3. كل خلية «Denied» في `docs/rls-matrix.md` مغطاة باختبار واحد على الأقل (12 خلية → DB-N01..N12).
4. `deno test` للوحدات النقية أخضر + EF-I01/I02/I03/I07 خضراء.
5. `flutter test` أخضر ويشمل MOB-U01..U05 وMOB-W02.
6. `gitleaks` نظيف + SEC-03 أخضر.
7. فحص يدوي موثق: كسر عمدي لسياسة RLS على فرع → CI يحمر (إثبات أن البوابة تعمل).

### جاهزية «مرحلة 1 — تجريبي مغلق»
1. كل ما سبق + DB-I07..I12 وEF-I04..I06 وMOB-U06/W01/W03 خضراء.
2. تغطية أسطر ≥ **70%** على `mobile/lib/core/` (sync + database) — مقاسة بـ lcov في CI.
3. تغطية ≥ **60%** على `supabase/functions/_shared/`.
4. اختبار التزامن DB-I11/I12 ناجح 5 مرات متتالية في CI (flakiness = فشل).
5. بيانات بذرة staging موجودة و`supabase db reset` + seed ينتج بيئة قابلة للعرض (خطوة منفصلة في خطة أخرى، يُتحقق هنا).

### جاهزية «مرحلة 2 — إطلاق تجاري»
1. كل ما سبق + MOB-E01/E02 (integration_test على جهاز/محاكي في CI أو Firebase Test Lab) خضراء.
2. golden tests الثلاثة مستقرة (لا فشل في 10 تشغيلات).
3. فحص صحة يومي مجدول في CI (`schedule: cron`) على staging: مطابقة `business_customer_balances` مقابل مجموع `ledger_entries` لكل مستأجر (الفحص الموصى به في `10-tests:§6.4`).
4. صفر فشل CI على `main` لمدة 14 يوماً متتالية أثناء التجريبي المغلق.

---

## 8. سجل الخطوات التنفيذية المرقمة

### [فوري — خلال 24 ساعة]

**الخطوة 1 — بوابة CI الأولى**
- الملف المستهدف: `.github/workflows/ci.yml` (جديد، جذر المستودع).
- التغيير: إنشاء الخط بمراحل §6.2 (secrets + supabase-db + flutter بصيغتها الدنيا: lint + pgTAP الحالية + analyze + test الحالي).
- معيار النجاح: PR تجريبي يُظهر المراحل خضراء؛ وكسر عمدي في اختبار pgTAP يحوّلها حمراء.
- الاعتماديات: لا شيء. **ملاحظة:** مرحلة `db reset` ستكشف فوراً كسر الترحيل 0012 (X-1) — متوقع أن تكون حمراء حتى تجميد/إصلاح 0012 (خطة المخطط المعماري للباكند).
- الجهد: 1 يوم.

**الخطوة 2 — فحص الأسرار**
- الملف: `.github/workflows/ci.yml` (مرحلة `secrets` و`client-secrets-guard`).
- التغيير: gitleaks بكامل التاريخ + فحص SEC-03 النصي.
- معيار النجاح: يكشف `owa_k1_...` الحالي في `send-whatsapp-otp/index.ts:4-5` (أحمر متوقع حتى تدويره — خطة الأمن).
- الاعتماديات: الخطوة 1. الجهد: ساعتان.

**الخطوة 3 — اختبار انحدار الترحيلات**
- الملف: `.github/workflows/ci.yml` (خطوة `supabase db reset --yes` ضمن `supabase-db`).
- التغيير: تطبيق كامل الترحيلات من الصفر عند كل PR.
- معيار النجاح: يفشل الآن بسبب 0012 (توثيق الفشل كدليل X-1)، ويخضر بعد إصلاح/تجميد 0012.
- الاعتماديات: الخطوة 1. الجهد: ساعة (ضمن الخطوة 1 عملياً).

### [مرحلة صفر — يحظر الإطلاق]

**الخطوة 4 — اختبارات عزل المستأجرين**
- الملف: `debt-ledger-supabase/supabase/tests/database/010_rls_tenant_isolation.sql` (جديد).
- التغيير: DB-N01..N05 بقالب §3.2–3.4 مع sanity checks إيجابية.
- معيار النجاح: `supabase test db` أخضر؛ حذف سياسة `ledger_entries_select_allowed` عمداً على فرع → فشل DB-N02.
- الاعتماديات: الخطوة 1. الجهد: 2 يوم.

**الخطوة 5 — اختبارات صلاحيات الأدوار السلبية**
- الملف: `.../tests/database/011_rls_role_permissions.sql` (جديد).
- التغيير: DB-N06..N12 بقالب §3.5؛ ضبط رموز الأخطاء من `202607120002_functions_and_triggers.sql`.
- معيار النجاح: أخضر؛ منح `cashier` صلاحية العكس عمداً → فشل DB-N07.
- الاعتماديات: الخطوة 4 (إعادة استخدام سقالات البناء). الجهد: 1.5 يوم.

**الخطوة 6 — اختبارات الثوابت المالية**
- الملف: `.../tests/database/012_ledger_immutability.sql` (جديد).
- التغيير: DB-I01..I05 + DB-I14 (انحدار تريجر 0012).
- معيار النجاح: أخضر؛ ويثبت الرفض برمز الخطأ الصحيح لا بصمت.
- الاعتماديات: الخطوة 4. الجهد: 1 يوم.

**الخطوة 7 — حسم واختبار سياسة الدفع الزائد**
- الملف: `012_ledger_immutability.sql` + تعديل `README.md:100` أو `003_double_entry_accounting.sql:33` حسب القرار.
- التغيير: بعد قرار المخطط المعماري (منع أم رصيد دائن)، كتابة DB-I06 وحذف/تعديل التأكيد المتناقض في `003:33,47-58`.
- معيار النجاح: لا تناقض بين `README.md` و`First-version.md:1037-1043` والاختبارات — grep يدوي للتحقق.
- الاعتماديات: قرار السياسة (خطة الباكند). الجهد: 0.5 يوم.

**الخطوة 8 — إعادة هيكلة `_shared` للدوال**
- الملفات: `supabase/functions/_shared/phone_crypto.ts`، `file_integrity.ts`، `http_guard.ts` (جديدة) + تحديث imports في الدوال التسع.
- التغيير: استخراج المنطق النقي (§4.1) بلا تغيير سلوك.
- معيار النجاح: الدوال تُخدَّم محلياً بلا تغيير في الاستجابات (فحص دخاني يدوي).
- الاعتماديات: إزالة أسرار OpenWA (خطة الأمن). الجهد: 1 يوم.

**الخطوة 9 — اختبارات وحدة Deno**
- الملفات: `supabase/functions/_shared/*_test.ts`.
- التغيير: EF-U01..U03.
- معيار النجاح: `deno test --allow-env` أخضر في CI (مرحلة edge-unit).
- الاعتماديات: الخطوة 8. الجهد: 1 يوم.

**الخطوة 10 — اختبارات تكامل الدوال الحرجة**
- الملفات: `supabase/functions/tests/integration/security_test.ts` (جديد).
- التغيير: EF-I01/I02/I03/I07 — بما فيها انحدار IDOR بتوليد JWT محلي.
- معيار النجاح: EF-I02 **أحمر الآن** (يثبت ثغرة `generate-statement/index.ts:425`) ويخضر بعد إصلاحها (خطة الأمن)؛ الباقي أخضر.
- الاعتماديات: الخطوة 8، إصلاح IDOR. الجهد: 2 يوم.

**الخطوة 11 — حقن الاعتماديات في طبقة بيانات الموبايل**
- الملفات: `mobile/lib/core/database/app_database.dart`، `mobile/lib/core/sync/sync_engine.dart`.
- التغيير: منشئات اختبارية `@visibleForTesting` (قاعدة ffi، connectivity مزيف، عميل RPC مزيف) — §5.3.
- معيار النجاح: الكود الإنتاجي بلا تغيير سلوكي (التطبيق يقلع واختبار smoke الحالي يمر).
- الاعتماديات: لا شيء. الجهد: 1 يوم.

**الخطوة 12 — اختبارات وحدة الطابور والمزامنة**
- الملفات: `mobile/test/core/database/app_database_test.dart`، `mobile/test/core/sync/sync_engine_test.dart` + إضافات `pubspec.yaml` (§5.1).
- التغيير: MOB-U01..U04 بـ `sqflite_common_ffi` و`fake_async`.
- معيار النجاح: `flutter test` أخضر محلياً وفي CI؛ حذف الـ guard `_isProcessing` عمداً → فشل MOB-U03.
- الاعتماديات: الخطوة 11. الجهد: 2–3 أيام.

**الخطوة 13 — اختبار عقد RPC (انحدار X-3)**
- الملفات: `mobile/test/contracts/rpc_signatures.json` + `mobile/test/features/merchant/data/merchant_repository_contract_test.dart`.
- التغيير: MOB-U05 — استخراج التواقيع من `docs/api-reference-and-operational-flow.md` ومطابقة معاملات `merchant_repository.dart:129-143,190-196`.
- معيار النجاح: **أحمر الآن** (12 مقابل 9 معاملاً) ويخضر بعد توحيد العقد (خطة الباكند/الموبايل).
- الاعتماديات: لا شيء. الجهد: 1 يوم.

### [مرحلة 1 — تجريبي مغلق]

**الخطوة 14 — سيناريوهات النزاعات الكاملة**
- الملف: `.../tests/database/013_dispute_lifecycle.sql` (جديد).
- التغيير: DB-I07..I10.
- معيار النجاح: أخضر؛ السماح باعتراض ثانٍ عمداً → فشل DB-I07.
- الاعتماديات: الخطوة 5. الجهد: 1.5 يوم.

**الخطوة 15 — اختبارات التزامن**
- الملف: `.../tests/database/014_concurrency.sql` + سكربت CI مساعد (جلستا psql متوازيتان).
- التغيير: DB-I11..I12.
- معيار النجاح: 5 تشغيلات CI متتالية خضراء (§7 مرحلة 1 بند 4).
- الاعتماديات: الخطوة 6. الجهد: 2 يوم.

**الخطوة 16 — اختبارات تعدد العملات**
- الملف: `.../tests/database/015_multi_currency.sql` (جديد).
- التغيير: DB-I05 (مكتملة) + DB-I15 بعد إصلاح 0012؛ اختبار عرض/فصل الأرصدة بالعملة.
- معيار النجاح: أخضر بعد إصلاح 0012 (خطة الباكند) — **محظور كتابته قبل تجميد قرار 0012**.
- الاعتماديات: إصلاح/إعادة كتابة 0012. الجهد: 1.5 يوم.

**الخطوة 17 — استكمال تكامل الدوال**
- الملفات: `supabase/functions/tests/integration/*.test.ts`.
- التغيير: EF-I04..I06 (بما فيه انحدار العامل المكسور `process-automation-rules/index.ts:213-221,274`).
- معيار النجاح: EF-I06 أحمر الآن، أخضر بعد إصلاح العامل.
- الاعتماديات: الخطوة 10، إصلاح العامل (خطة الباكند). الجهد: 2 يوم.

**الخطوة 18 — اختبارات وحدات/ودجت الموبايل التكميلية**
- الملفات: `mobile/test/features/**` (MOB-U06, MOB-W01..W03).
- التغيير: mocks بـ mocktail للـ repository؛ تأكيدات سلوكية لا بصرية.
- معيار النجاح: أخضر؛ MOB-W02 يثبت غياب الرصيد الثابت `'450,000 ر.ي'` بعد ربط شاشة العميل فعلياً.
- الاعتماديات: ربط شاشة العميل بالباكند (خطة الموبايل). الجهد: 2 يوم.

**الخطوة 19 — بوابة التغطية**
- الملف: `.github/workflows/ci.yml` (تفعيل عتبة lcov في مرحلة flutter).
- التغيير: فرض 70% على `lib/core/` و60% على `_shared/` (§7).
- معيار النجاح: PR يخفض التغطية تحت العتبة يحمر.
- الاعتماديات: الخطوات 12، 18. الجهد: 0.5 يوم.

**الخطوة 20 — فحص الصحة اليومي المجدول على staging**
- الملف: `.github/workflows/staging-health.yml` (جديد — `schedule: cron '17 3 * * *'`).
- التغيير: استعلام مطابقة الأرصدة (`business_customer_balances` مقابل مجموع القيود) + استدعاء `verify-statement` دخاني.
- معيار النجاح: أي انحراف رصيد يفتح issue آلياً.
- الاعتماديات: بيئة staging وبيانات بذرة (خطة أخرى). الجهد: 1 يوم.

### [مرحلة 2 — إطلاق تجاري]

**الخطوة 21 — اختبارات E2E للموبايل**
- الملفات: `mobile/integration_test/offline_sync_test.dart`، `otp_flow_test.dart`.
- التغيير: MOB-E01..E02 على محاكي في CI (أو Firebase Test Lab).
- معيار النجاح: دين أوفلاين يظهر مرة واحدة في الباكند بعد الاتصال.
- الاعتماديات: حسم مزود OTP الإنتاجي (`10-tests:§4.19`). الجهد: 3 أيام.

**الخطوة 22 — golden tests الضيقة**
- الملفات: `mobile/test/golden/` (3 شاشات — MOB-G01).
- التغيير: لقطات مرجعية بعد تثبيت الثيم.
- معيار النجاح: 10 تشغيلات مستقرة.
- الاعتماديات: تثبيت التصميم. الجهد: 1 يوم.

**الخطوة 23 — اختبار أداء مالي أساسي**
- الملف: `.../tests/database/016_performance_smoke.sql` أو سكربت pgbench.
- التغيير: توليد 10k قيد لمستأجر واحد وقياس زمن كشف الحساب مقابل هدف `First-version.md:1362-1366`.
- معيار النجاح: توليد الكشف < 4 ثوانٍ على جهاز CI.
- الاعتماديات: الخطوة 20. الجهد: 1 يوم.

**الخطوة 24 — اختبار اختراق storage الموثق**
- الملف: `supabase/functions/tests/integration/storage_security_test.ts`.
- التغيير: SEC-02 — محاولة قراءة مرفق بلا تفويض metadata (`README.md:103`).
- معيار النجاح: 403/404 لكل محاولة غير مفوضة.
- الاعتماديات: سياسات storage النهائية (خطة الأمن). الجهد: 1 يوم.

---

## 9. مخاطر الخطة وملاحظات التسليم

1. **اعتماد حرج على خطط أخرى:** الخطوات 7، 10، 13، 16، 17 تفترض قرارات/إصلاحات من خطط الباكند والأمن والموبايل (تجميد 0012، إصلاح IDOR، توحيد عقد RPC، تدوير OpenWA). اختبارات الانحدار (EF-I02، MOB-U05، DB-I13) **تُكتب حمراء أولاً** عمداً — هذا مقصود كدليل ثبوت للثغرات.
2. **حظر التسلسل:** لا تبدأ الخطوة 16 قبل حسم مصير 0012 — كتابة اختبارات فوق تريجر مكسور (`direction='in'` مقابل enum `0012:59`) هدر مؤكد.
3. **flakiness التزامن:** DB-I11/I12 هي الأكثر عرضة للهشاشة؛ قاعدة «5 تشغيلات» في §7 إلزامية لا شكلية.
4. **حجم الجهد الكلي:** ≈ 30 يوم عمل موزعة على 4 مراحل، متوافقة مع تقدير التقرير (2–3 أسابيع للتجريبي المغلق) بافتراض مهندس اختبارات واحد بدوام كامل.
