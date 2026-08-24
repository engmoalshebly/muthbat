# خطة إصلاح الأمان والأسرار — نظام دفتر الديون (مُثبَت)

> **المؤلف:** مخطط_إصلاح_الأمان_والأسرار (Security & Secrets Remediation Architect)
> **النطاق:** تسريب مفتاح OpenWA، إعادة تصميم OTP على الخادم، IDOR في `generate-statement`، تخويل رفع الملفات، سياسات Storage، rate limiting، وCORS.
> **المراجع:** `analysis-reports/03-security-rls.md` (ح-1، ح-5، ع-1، ع-2، ع-3)، `analysis-reports/04-edge-functions.md` (ح-1، ح-2، ح-3، ع-1، م-3، م-4، منخفض-1، منخفض-3)، `analysis-reports/09-docs-vs-implementation.md` (C-3).
> **قاعدة التصنيف:** [فوري] خلال 24 ساعة · [مرحلة صفر] يحظر الإطلاق · [مرحلة 1] تجريبي مغلق · [مرحلة 2] إطلاق تجاري.

---

## 0. ملخص القرارات المعمارية المحسومة

| # | القرار | الخيارات | التوصية المحسومة |
|---|--------|----------|-------------------|
| D1 | مصير دالة `send-whatsapp-otp` | (أ) حذفها كلياً ونقل OTP إلى RPC + عامل خلفية · (ب) إعادة كتابتها كنقطة OTP كاملة على الخادم | **(ب)** — الدالة موجودة ومنشورة، وإعادة كتابتها أسرع من بناء مسار RPC+عامل جديد، وتبقي قناة واتساب قابلة للتبديل لمزود SMS لاحقاً خلف نفس الواجهة |
| D2 | تخزين رموز OTP | (أ) نص صريح مشفر AES · (ب) HMAC-SHA256 | **(ب)** — الرمز قصير العمر ولا حاجة لاسترجاعه؛ التجزئة تمنع كشف الرموز حتى لو تسربت القاعدة، وتطابق نمط `customer_contacts` المعتمد (`202607120001_core_schema.sql:80-91`) |
| D3 | مفتاح rate limit في `verify-statement` | (أ) أول قيمة في `x-forwarded-for` (قابلة للتزوير) · (ب) آخر قيمة (يضيفها الـ edge) · (ج) حد لكل رمز تحقق | **(ب)+(ج) معاً** — لا توجد قيمة IP موثوقة 100% في بيئة Edge، لذا ندعّس الحد: IP (آخر قيمة في الترويسة) + حد عالمي لكل رمز |
| D4 | سلوك CORS عند غياب `ALLOWED_ORIGIN` | (أ) السقوط إلى `"*"` (الحالي، فشل مفتوح) · (ب) الفشل المغلق | **(ب)** — فشل مغلق: رفض الطلب برمز 403 ورسالة واضحة؛ بيئة منسية الضبط يجب أن تكون غير عاملة لا مفتوحة |
| D5 | إثبات نجاح OTP لمسار التسجيل | (أ) العميل يستدعي `bootstrap-user-contact` بعد التحقق بلا دليل · (ب) رمز تحقق موقّت يصدره الخادم ويُطالب في bootstrap | **(ب)** — بلا دليل خادمي يبقى إثبات ملكية الهاتف شكلياً؛ نصدر `phone_proof_token` (JWT قصير العمر موقّع بسر خادمي) يستهلك مرة واحدة |

---

## 1. تدوير الأسرار فورياً [فوري — خلال 24 ساعة]

### الخطوة 1.1 — إبطال مفتاح OpenWA المسرَّب
- **الهدف:** كان مفتاح OpenWA ومعرّف الجلسة مكشوفين في الكود القديم، وتم حجبهما من المستودع.
- **التغيير المطلوب (تشغيلي، لا كود):**
  1. الدخول إلى لوحة تحكم OpenWA Enterprise وإبطال (revoke) المفتاح الحالي وإصدار مفتاح جديد، وتدوير `sessionId` إن أمكن.
  2. فحص سجلات OpenWA (message logs / API access logs) خلال آخر 90 يوماً بحثاً عن استخدام مسيء: رسائل لأرقام غير معروفة، أحجام إرسال شاذة، طلبات من عناوين IP غير متوقعة. توثيق النتيجة في تقرير حادثة (incident note) حتى لو كانت سلبية.
  3. تسجيل المفتاح الجديد في أسرار Supabase فقط: `supabase secrets set OPENWA_API_KEY=... OPENWA_SESSION_ID=... OPENWA_BASE_URL=...`.
- **معيار التحقق:** المفتاح القديم مرفوض من OpenWA (اختبار curl واحد يعيد 401/403)؛ لا وجود للقيمة الجديدة في أي ملف بالمستودع (`grep -r "owa_k1_"` يعيد صفر نتائج).
- **الاعتماديات:** وصول إداري لحساب OpenWA ولمشروع Supabase.
- **الجهد:** 1–2 ساعة.

### الخطوة 1.2 — إزالة القيم الافتراضية من الكود والفشل الصريح
- **الملف المستهدف:** `debt-ledger-supabase/supabase/functions/send-whatsapp-otp/index.ts:3-5`.
- **التغيير المطلوب:** حذف القيم الافتراضية نهائياً واستخدام نمط `required()` الموجود في `_shared/supabase.ts:3-7`:
  ```ts
  const OPENWA_BASE_URL = required("OPENWA_BASE_URL");
  const OPENWA_SESSION_ID = required("OPENWA_SESSION_ID");
  const OPENWA_API_KEY = required("OPENWA_API_KEY");
  ```
  (هذه الخطوة تُستوعب ضمن إعادة الكتابة الكاملة في الخطوة 2.3 — إن تأخرت إعادة الكتابة، تُنفَّذ هذه كإصلاح ساخن مستقل).
- **معيار التحقق:** تشغيل الدالة محلياً بلا متغيرات بيئة يفشل بخطأ `Missing required environment variable` عند الإقلاع، لا يرسل أي رسالة.
- **الاعتماديات:** الخطوة 1.1 (وجود أسرار جديدة).
- **الجهد:** 0.5 ساعة (أو مدمجة في 2.3).

### الخطوة 1.3 — تنظيف تاريخ git
- **الملف المستهدف:** تاريخ المستودع كاملاً (المفتاح في commit history).
- **التغيير المطلوب:** بما أن المفتاح أُبطل في 1.1، فتنظيف التاريخ **تقليل مخاطر ثانوي** وليس شرط نجاة. القرار: تنفيذ `git filter-repo` (أو BFG) لإزالة سلسلة المفتاح ومعرّف الجلسة من كل التاريخ، ثم force-push وإعادة استنساخ لكل أعضاء الفريق. إن كان المستودع قد نُشر علناً أو سُرِّب، يُعامل المفتاح كمخترَم بغض النظر عن التنظيف (وهو ما تغطيه 1.1 أصلاً).
- **معيار التحقق:** `git log -S "owa_k1_18037727" --all` يعيد صفر نتائج بعد التنظيف؛ فحص مستقل بأداة كشف أسرار (مثل `gitleaks detect`) على كامل التاريخ يمر نظيفاً.
- **الاعتماديات:** الخطوة 1.1 أولاً (حتى لا يبقى مفتاح حي حتى لو بقي في التاريخ مؤقتاً)؛ تنسيق مع الفريق لتجميد الـ push أثناء إعادة الكتابة.
- **الجهد:** 2–3 ساعات + نافذة تنسيق.

### الخطوة 1.4 — منع تكرار التسريب (حارس ما قبل الالتزام)
- **الملف المستهدف:** جديد — `.gitleaks.toml` في جذر المستودع + خطوة CI.
- **التغيير المطلوب:** إضافة فحص `gitleaks` في CI وكـ pre-commit hook اختياري، مع قاعدة مخصصة لأنماط `owa_k1_[0-9a-f]{64}` وعناوين LAN الداخلية (`192.168.`).
- **معيار التحقق:** التزام تجريبي يحمل سلسلة مفتاح وهمي يُرفض من CI.
- **الاعتماديات:** لا شيء.
- **الجهد:** 1 ساعة.

---

## 2. إعادة تصميم OTP كاملاً على الخادم [مرحلة صفر — يحظر الإطلاق]

### الحالة الحالية (للمرجعية)
- التوليد والتحقق والتخزين كلها في العميل: `whatsapp_otp_service.dart:95-99` (توليد)، `:39` (خريطة `_activeOtps` في الذاكرة)، `:188-251` (تحقق محلي)، مع **باب خلفي صريح**: الرمزان `123456` و`000000` مقبولان دائماً (`:196-199`).
- العميل يتصل بـ OpenWA مباشرة بمفتاح مضمّن (`:28-36`) ولا يستدعي دالة Edge أصلاً.
- الدالة `send-whatsapp-otp/index.ts:13-79` بلا `requireUser` ولا rate limit وتقبل `otpCode` من المتصل (`:25`) مع CORS wildcard (`:17`).
- `config.toml:59-61` يعطّل `[auth.sms]` — أي لا بديل مزوّد؛ OTP المخصص هو آلية إثبات الهاتف الوحيدة.

### مخطط التدفق المستهدف

```
العميل (Flutter)                     Edge Functions                    PostgreSQL (private)              OpenWA
    │                                    │                                  │                             │
    │── POST /send-whatsapp-otp ────────▶│                                  │                             │
    │   { phone }                        │── service_request_otp(phone) ───▶│ توليد رمز 6 أرقام (CSPRNG)   │
    │                                    │                                  │ تخزين HMAC(code)+TTL+حدود    │
    │                                    │◀── { challengeId, code } ────────│                             │
    │                                    │── إرسال الرمز عبر واتساب ─────────────────────────────────────▶│
    │◀── { challengeId, expiresIn } ─────│                                  │                             │
    │                                    │                                  │                             │
    │── POST /verify-whatsapp-otp ──────▶│                                  │                             │
    │   { challengeId, code }            │── service_verify_otp(id, code) ─▶│ مقارنة HMAC، عدّ المحاولات،  │
    │                                    │                                  │ إن صح: consumed + إصدار دليل │
    │◀── { phoneProofToken } ────────────│◀── { proofToken } ───────────────│                             │
    │                                    │                                  │                             │
    │── POST /bootstrap-user-contact ───▶│ (يتطلب phoneProofToken صالحاً)   │                             │
```

### الخطوة 2.1 — ترحيل قاعدة بيانات: جدول التحديات ودوال الخدمة
- **الملف المستهدف:** جديد — `debt-ledger-supabase/supabase/migrations/202608190013_otp_challenges.sql` (أو الرقم التسلسلي التالي المتاح بعد حسم مصير 0012).
- **التغيير المطلوب:**
  ```sql
  create table private.otp_challenges (
    id uuid primary key default gen_random_uuid(),
    phone_e164 text not null,
    code_hmac text not null,                 -- HMAC-SHA256(code, OTP_HMAC_KEY)
    purpose text not null default 'phone_verification',
    attempts_left smallint not null default 5,
    expires_at timestamptz not null default now() + interval '5 minutes',
    consumed_at timestamptz,
    last_sent_at timestamptz not null default now(),
    created_at timestamptz not null default now()
  );
  create index idx_otp_challenges_phone_active
    on private.otp_challenges (phone_e164) where consumed_at is null;
  ```
  ودالتان `security definer set search_path=''` مقيدتان بـ `service_role` فقط (نمط `202607120003_rls_and_grants.sql:86-92`):
  - `private.service_request_otp(p_phone text) returns (challenge_id uuid, code text)` — تتحقق داخلياً من: صيغة E.164 (`^\+[1-9]\d{7,14}$`)، فترة انتظار 60 ثانية منذ `last_sent_at`، وسقف يومي 10 رموز/رقم عبر `service_consume_rate_limit` (`202608140006:158-182`)؛ تولّد الرمز بـ `gen_random_bytes`، تخزّن HMAC فقط، وتعيد الرمز الصريح للدالة المستدعية فقط.
  - `private.service_verify_otp(p_challenge_id uuid, p_code text) returns text` — ترفض إن: منتهية الصلاحية، مستهلكة، `attempts_left = 0`؛ تُنقص المحاولات ذرّياً (`update ... returning`)؛ عند النجاح تضبط `consumed_at` وتعيد `phone_proof_token` (انظر 2.4).
- **معيار التحقق:** اختبار pgTAP جديد يثبت: (أ) رفض إعادة الإرسال قبل 60 ثانية، (ب) قفل التحدي بعد 5 محاولات خاطئة، (ج) رفض الرمز بعد انتهاء 5 دقائق، (د) استهلاك أحادي (تحقق ثانٍ بنفس الرمز يفشل)، (هـ) `revoke execute ... from public, anon, authenticated` مفعّل (استعلام `has_function_privilege`).
- **الاعتماديات:** سر جديد `OTP_HMAC_KEY` في أسرار Supabase (يولَّد عشوائياً 32 بايت).
- **الجهد:** 4–6 ساعات.

### الخطوة 2.2 — نقطة تحقق مستقلة `verify-whatsapp-otp`
- **الملف المستهدف:** جديد — `debt-ledger-supabase/supabase/functions/verify-whatsapp-otp/index.ts` + قسم `[functions.verify-whatsapp-otp] verify_jwt = false` في `config.toml` (بعد سطر 85).
- **التغيير المطلوب:** POST عام (المستخدم لم يسجل دخوله بعد) لكن محدود المعدل: `service_consume_rate_limit` بمفتاح مركّب `otp-verify:{challengeId}` بحد 10/ساعة + حد IP (نمط الخطوة 5.1). يستدعي `service_verify_otp` ويعيد `{ valid, phoneProofToken? }` فقط — بلا أي تفاصيل إضافية.
- **معيار التحقق:** اختبار تكامل: رمز خاطئ 5 مرات → 429/403؛ رمز صحيح → رمز دليل؛ إعادة نفس الرمز → `invalid`.
- **الاعتماديات:** 2.1.
- **الجهد:** 2–3 ساعات.

### الخطوة 2.3 — إعادة كتابة `send-whatsapp-otp` بالكامل
- **الملف المستهدف:** `debt-ledger-supabase/supabase/functions/send-whatsapp-otp/index.ts` (استبدال كامل للأسطر 1-79) + إضافة `[functions.send-whatsapp-otp] verify_jwt = false` صراحة في `config.toml` (الدالة غير مدرجة حالياً — `config.toml:63-85`).
- **التغيير المطلوب:**
  ```ts
  serve(async (req) => {
    const preflight = optionsResponse(req);              // _shared/cors.ts المشدد (الخطوة 5.2)
    if (preflight) return preflight;
    if (req.method !== "POST") return errorResponse(req, 405, "method_not_allowed", "POST is required");
    try {
      const { phone } = await readJson<{ phone: string }>(req);   // لا otpCode من العميل إطلاقاً
      const e164 = normalizeE164(phone);                          // regex ^\+[1-9]\d{7,14}$
      if (!e164) return errorResponse(req, 422, "invalid_phone", "...");
      const admin = serviceClient();
      // حد IP + الحدود الداخلية في service_request_otp (60s cooldown، 10/يوم)
      const ip = clientIp(req);                                   // الخطوة 5.1
      await admin.rpc("service_consume_rate_limit",
        { p_scope: "otp-request-ip", p_subject_key: ip, p_max_hits: 20, p_window_seconds: 3600 });
      const { data, error } = await admin.rpc("service_request_otp", { p_phone: e164 });
      if (error) return errorResponse(req, 429, "otp_rate_limited", "...");
      // الإرسال عبر OpenWA بأسرار البيئة فقط (required()) — لا قيم افتراضية
      await sendOpenWaText(e164, otpMessage(data.code));
      return json(req, { challengeId: data.challenge_id, expiresInSeconds: 300 }, 201);
    } catch (e) { /* فشل مغلق، بلا تسريب error.message الخام */ }
  });
  ```
  ملاحظات حرجة: الاستجابة **لا تتضمن الرمز أبداً**؛ فشل OpenWA بعد إنشاء التحدي يعيد 502 ويُسجَّل، مع عدم كشف الرمز؛ رسائل الخطأ عبر whitelist أكواد (معالجة منخفض-4 في تقرير Edge Functions).
- **معيار التحقق:** (أ) استدعاء بلا JWT ينجح لكن بحد 20/ساعة/IP، (ب) جسم يحمل `otpCode` يُتجاهل، (ج) `grep -n "owa_k1_" supabase/functions` صفر نتائج، (د) فشل الإقلاع بلا أسرار البيئة.
- **الاعتماديات:** 1.1، 2.1، 5.1، 5.2.
- **الجهد:** 4–5 ساعات.

### الخطوة 2.4 — ربط إثبات الهاتف بمسار التسجيل (`phone_proof_token`)
- **الملف المستهدف:** `debt-ledger-supabase/supabase/functions/bootstrap-user-contact/index.ts` (حالياً يقبل الهاتف بلا دليل ملكية — يقرأ `PHONE_KEY_VERSION` في سطر 25) + دالة `service_verify_otp` في 2.1.
- **التغيير المطلوب:** عند نجاح التحقق، يصدر الخادم رمز دليل: JWT موقّع بـ `OTP_HMAC_KEY` (HS256) بحمولة `{ phone_e164, challenge_id, exp: now+10min }`. دالة `bootstrap-user-contact` تُعدَّل لتطلب `phoneProofToken` وتتحقق من توقيعه وانتهائه ومطابقة `phone_e164` للمدخل، وتسجّل `challenge_id` كمستهلك (منع إعادة الاستخدام عبر جدول أو عبر consumed_at في التحدي).
- **معيار التحقق:** استدعاء `bootstrap-user-contact` برقم لم يجتز OTP يُرفض 403؛ رمز دليل لرقم مختلف يُرفض؛ رمز منتهٍ (>10 دقائق) يُرفض.
- **الاعتماديات:** 2.1، 2.2.
- **الجهد:** 3–4 ساعات.

### الخطوة 2.5 — تنظيف العميل (Flutter)
- **الملف المستهدف:** `mobile/lib/core/services/whatsapp_otp_service.dart` (إعادة كتابة شبه كاملة).
- **التغيير المطلوب:**
  1. حذف الثوابت `sessionId` و`apiKey` (`:28-29`) وقائمة `candidateUrls` ذات عناوين LAN (`:32-36`) ودالة `_resolveWorkingBaseUrl` (`:49-77`) و`_headers` (`:43-46`) — العميل لا يعرف OpenWA إطلاقاً.
  2. حذف `generateOtpCode` (`:95-99`) وخريطة `_activeOtps` (`:39`) ومنطق التحقق المحلي (`:188-251`) وباب `123456`/`000000` الخلفي (`:196-199`).
  3. `sendOtp` تصبح استدعاء `POST {SUPABASE_URL}/functions/v1/send-whatsapp-otp` بجسم `{ phone }` وتعيد `challengeId` فقط؛ `verifyOtp` تستدعي `verify-whatsapp-otp` وتعيد `phoneProofToken` لطبقة التسجيل.
  4. الاحتفاظ بحراس UX المحليين (cooldown 60s، in-flight guard `:112-135`) كتحسين تجربة فقط — الحدود الحقيقية على الخادم.
- **معيار التحقق:** فحص ثابت: `grep -rn "owa_k1_\|192.168.0.134\|10.0.2.2" mobile/lib` صفر نتائج؛ اختبار ويدجت/تكامل: مسار تسجيل كامل عبر محاكي ضد بيئة staging؛ تفكيك APK تجريبي (jadx) لا يكشف أي سر أو عنوان داخلي.
- **الاعتماديات:** 2.2، 2.3.
- **الجهد:** 4–6 ساعات + اختبار يدوي.

---

## 3. إصلاح IDOR في `generate-statement` [مرحلة صفر — يحظر الإطلاق]

### الخطوة 3.1 — فحص ملكية قبل جلب الكشف
- **الملف المستهدف:** `debt-ledger-supabase/supabase/functions/generate-statement/index.ts:425-457`.
- **المشكلة:** عند تمرير `statementId` (سطر 425) يُجلب الكشف عبر `serviceClient()` (يتجاوز RLS) في `:449-453` بلا فحص، ثم تُعاد الأرصدة ورابط PDF موقّع (`:534-552`).
- **التغيير المطلوب:** قبل Step 2، تحقق تفويض عبر **عميل المستخدم** الخاضع لـ RLS (المتاح من `requireUser` في `:422`):
  ```ts
  if (statementId) {
    const { data: allowed, error } = await client
      .from("statements").select("id").eq("id", statementId).maybeSingle();
    if (error) throw error;
    if (!allowed) return errorResponse(request, 404, "statement_not_found",
      "Statement snapshot not found."); // 404 وليس 403 — منع تعداد المعرّفات
  }
  ```
  البديل المرفوض: RPC تحقق مخصص — لا حاجة له ما دامت سياسات SELECT على `statements` تفرض العضوية/الملكية أصلاً (تأكد من ذلك في معيار التحقق). إن تبين أن سياسات `statements` لا تغطي دوراً مشروعاً (مثل viewer)، يُضاف RPC `private.can_access_statement` بدلاً من توسيع السياسة.
- **معيار التحقق:** اختبار تكامل: مستخدم A ينشئ كشفاً؛ مستخدم B (مصادق، غير طرف) يستدعي الدالة بـ `statementId` الخاص بـ A → 404 ولا يُنشأ رابط موقّع ولا يُرفع PDF؛ نفس الاختبار للعميل المرتبط (طرف مشروع) → 201. اختبار pgTAP سلبي يثبت أن سياسة SELECT على `statements` ترفض القراءة العابرة للمستأجرين.
- **الاعتماديات:** لا شيء (مستقل).
- **الجهد:** 1–2 ساعة.

### الخطوة 3.2 — فصل رمز التحقق عن مسار الملف
- **الملف المستهدف:** `generate-statement/index.ts:506` (`objectPath` يتضمن `verification_code`).
- **التغيير المطلوب:** تغيير المسار إلى `statements/${header.id}/${crypto.randomUUID()}.pdf`؛ رمز التحقق يبقى في قاعدة البيانات فقط. من يملك رابط التحميل الموقّع لا يملك رمز التحقق العلني ضمنياً (منخفض-3 في تقرير RLS).
- **معيار التحقق:** الاستجابة والمسار المخزن لا يحتويان `verification_code`؛ `verify-statement` ما زال يعمل بالرمز من القاعدة.
- **الاعتماديات:** 3.1.
- **الجهد:** 0.5 ساعة.

---

## 4. إصلاح تخويل رفع الملفات وقيود المحتوى [مرحلة صفر — يحظر الإطلاق]

### الخطوة 4.1 — استبدال فحص القراءة بفحص صلاحية كتابة
- **الملفات المستهدفة:** `signed-document-upload/index.ts:10-14, 27` و`finalize-document-upload/index.ts:9-13, 27` (دالة `canAccessEntity` مكررة في كليهما).
- **المشكلة:** نجاح `SELECT` عبر RLS يعني «يمكنه الرؤية» لا «يمكنه الإرفاق» — عميل read-only أو دور `viewer` يستطيع إرفاق ملفات بأي قيد يقرأه (تقرير RLS ع-2؛ تعارض مع `docs/rls-matrix.md:8-14`).
- **التغيير المطلوب:** استبدال `canAccessEntity` بدالة تفويض صريحة:
  - لـ `ledger_entry`: RPC جديد `private.can_attach_to_ledger_entry(p_entry_id uuid) returns boolean` يتحقق أن المستخدم عضو في النشاط بدور كتابة `owner/admin/accountant/cashier` عبر `private.is_business_member` (نفس مصفوفة أدوار إنشاء القيود في `202608140010:359`).
  - لـ `dispute_message`: التحقق أن المستخدم طرف في النزاع (عضو النشاط بأدوار الكتابة، أو العميل صاحب النزاع عبر `private.is_customer_owner` مع `link_status='linked'` — اتساقاً مع تشديد 0006).
  - القرار المعماري: RPC واحد `security definer set search_path=''` مقيد بـ `authenticated` (فحص داخلي بـ `auth.uid()`) بدل منطق تفويض في TypeScript — يبقي قاعدة العمل في قاعدة البيانات قابلة للاختبار بـ pgTAP ومتسقة مع باقي الأوامر.
- **معيار التحقق:** اختبار pgTAP: دور `viewer` وعميل مرتبط read-only → `false`؛ `cashier` → `true` لقيود نشاطه. اختبار تكامل: جلسة رفع لقيد في نشاط لا يملك المستخدم دور كتابة فيه → 403 في كلتا الدالتين.
- **الاعتماديات:** ترحيل جديد (يتبع 2.1 تسلسلياً).
- **الجهد:** 3–4 ساعات.

### الخطوة 4.2 — فحص محتوى الملف (magic bytes)
- **الملف المستهدف:** `finalize-document-upload/index.ts:30-33` (بعد حساب الحجم والهاش).
- **التغيير المطلوب:** التحقق من التوقيعات الثنائية للأنواع الأربعة المسموحة قبل إدراج `files`:
  ```ts
  const MAGIC: Record<string, number[][]> = {
    "image/jpeg": [[0xFF, 0xD8, 0xFF]],
    "image/png":  [[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]],
    "image/webp": [[0x52, 0x49, 0x46, 0x46]],          // + "WEBP" عند الإزاحة 8
    "application/pdf": [[0x25, 0x50, 0x44, 0x46]],     // %PDF
  };
  ```
  رفض غير المطابق بـ 422 `file_content_mismatch` وحذف الكائن المرفوع من التخزين (تنظيف).
- **معيار التحقق:** رفع ملف HTML/تنفيذي مسمّى `image/jpeg` → 422 ولا صف في `files` ولا كائن متبقٍ في الباقة.
- **الاعتماديات:** 4.1.
- **الجهد:** 2 ساعة.

### الخطوة 4.3 — إزالة SVG من باقة `business-assets` العامة
- **الملف المستهدف:** ترحيل جديد يصحّح `202607120004_storage_realtime.sql:19` (لا تعديل الترحيل المطبق — ترحيل إصلاحي):
  ```sql
  update storage.buckets
  set allowed_mime_types = array['image/jpeg','image/png','image/webp']
  where id = 'business-assets';
  delete from storage.objects
  where bucket_id = 'business-assets' and metadata->>'mimetype' = 'image/svg+xml';
  ```
- **التغيير المطلوب:** حذف `image/svg+xml` (XSS مخزّن من باقة عامة — تقرير RLS ع-3) وحذف أي SVG موجود. إن كانت الشعارات SVG مطلوبة منتجياً: تُحوَّل إلى PNG عند الرفع (معالجة في Edge Function) — القرار: رفض SVG نهائياً في النسخة الأولى.
- **معيار التحقق:** محاولة رفع SVG للباقة تُرفض من سياسة التخزين؛ استعلام الباقة يعيد القائمة بلا SVG.
- **الاعتماديات:** لا شيء.
- **الجهد:** 1 ساعة.

### الخطوة 4.4 — التحقق من صيغة `sha256Hex`
- **الملف المستهدف:** `signed-document-upload/index.ts:24-26` و`:36`.
- **التغيير المطلوب:** إن وُجد `sha256Hex` يجب أن يطابق `/^[0-9a-f]{64}$/i` وإلا 422 (تقرير Edge Functions م-6).
- **معيار التحقق:** قيمة غير hex → 422 قبل إنشاء الجلسة.
- **الاعتماديات:** لا شيء.
- **الجهد:** 0.5 ساعة.

---

## 5. سياسة rate limiting وCORS صحيحة [مرحلة صفر — يحظر الإطلاق]

### الخطوة 5.1 — مفتاح IP غير قابل للتزوير + حد لكل رمز في `verify-statement`
- **الملف المستهدف:** `verify-statement/index.ts:13-14` + `_shared/http.ts` (إضافة مساعد `clientIp`).
- **المشكلة:** `x-forwarded-for.split(",")[0]` قيمة العميل القابلة للتزوير — تدويرها يلغي حد 30/ساعة (تقرير Edge Functions ع-1).
- **التغيير المطلوب:**
  1. مساعد مشترك يأخذ **آخر** قيمة في الترويسة (يضيفها الـ edge ولا يستطيع العميل تزوير ما بعدها):
     ```ts
     export function clientIp(req: Request): string {
       const fwd = req.headers.get("x-forwarded-for")?.split(",").map(s => s.trim()).filter(Boolean);
       return fwd?.at(-1) ?? "unknown";
     }
     ```
  2. حد ثانٍ لكل رمز تحقق: `service_consume_rate_limit` بمفتاح `statement-verification-code:{code}` بحد 20/ساعة — يمنع التعداد الموزع حتى مع تدوير IP.
  3. رفع إنتروبيا الرموز الجديدة: تعديل توليد `verification_code` في `202608140008:161` من 12 خانة hex (48 بت) إلى 20 خانة من أبجدية base32 بلا التباس (≈100 بت) عبر ترحيل إصلاحي يحدّث الدالة المولّدة {الرموز القديمة تبقى صالحة}.
  4. تحويل الدالة من GET بـ query string إلى POST بجسم (منخفض-6: الرمز يُسجَّل في سجلات البروكسي) — مع إبقاء GET مقبولاً مؤقتاً لمدة إصدار واحد للتوافق ثم إزالته.
- **معيار التحقق:** سكربت اختبار يرسل 40 طلباً بقيم `x-forwarded-for` مزوّرة متغيرة من نفس المصدر → 429 بعد الحد؛ 21 طلباً لنفس الرمز من IPs مختلفة → 429.
- **الاعتماديات:** لا شيء للبندين 1-2؛ ترحيل للبند 3.
- **الجهد:** 3–4 ساعات.

### الخطوة 5.2 — CORS بفشل مغلق وقائمة بيضاء إلزامية
- **الملفات المستهدفة:** `_shared/cors.ts:1-17` و`send-whatsapp-otp/index.ts:14-21` (يُزال معالج OPTIONS المحلي بالكامل في إعادة الكتابة 2.3) و`config.toml:48`.
- **التغيير المطلوب:**
  1. في `corsHeaders`: عند غياب `ALLOWED_ORIGIN` أو عدم تطابق الأصل → لا ترويسة `Access-Control-Allow-Origin` إطلاقاً (فشل مغلق) بدل السقوط إلى `"*"` (`:9`). و`optionsResponse` يعيد 403 عند أصل غير مسموح.
  2. ضبط `ALLOWED_ORIGIN` في أسرار البيئة لكل بيئة نشر (قائمة نطاقات التطبيق الفعلية؛ لتطبيق موبايل صرف يمكن تقييدها لنطاق لوحة الويب فقط).
  3. إزالة `http://127.0.0.1:3000` من `additional_redirect_urls` في بيئة الإنتاج (`config.toml:48` — متوسط-8 في تقرير RLS).
- **معيار التحقق:** طلب بأصل `https://evil.example` يعيد بلا ترويسة CORS مسموحة؛ طلب preflight من أصل مسموح يمر؛ إقلاع بلا `ALLOWED_ORIGIN` يرفض كل الطلبات العابرة للأصول.
- **الاعتماديات:** لا شيء.
- **الجهد:** 1–2 ساعة.

### الخطوة 5.3 — توحيد حدود المعدل على نقاط OTP ودليل العملاء
- **الملفات المستهدفة:** `send-whatsapp-otp` (20/ساعة/IP + 10/يوم/رقم — من 2.3)، `verify-whatsapp-otp` (10/ساعة/challenge — من 2.2)، `customer-directory/index.ts:21-24` (تشديد 60/ساعة إلى 30/ساعة/مستخدم لتخفيف تعداد الأرقام — منخفض-7).
- **معيار التحقق:** جدول حدود موثق في `docs/` + اختبارات تكامل لكل نقطة.
- **الاعتماديات:** 2.2، 2.3.
- **الجهد:** 1 ساعة.

---

## 6. بنود مؤجلة واعية [مرحلة 1 — تجريبي مغلق] و[مرحلة 2 — إطلاق تجاري]

### [مرحلة 1]
- **6.1** مقارنة ثابتة الزمن لـ `x-worker-secret` في `_shared/auth.ts:20-25` (HMAC compare بدل `!==`) — 1 ساعة.
- **6.2** توحيد `PHONE_KEY_VERSION`: `customer-directory/index.ts:35` يقرأ من البيئة مثل `bootstrap-user-contact/index.ts:25` — 0.5 ساعة.
- **6.3** whitelist أكواد الأخطاء في كل الدوال (منع تسريب `error.message` الخام — منخفض-4) — 3 ساعات.
- **6.4** تشديد حد `customer-directory` وتأخير الاستجابة الموحد للأرقام المسجلة/غير المسجلة (منخفض-7) — 2 ساعة.
- **6.5** اختبارات pgTAP سلبية شاملة (cross-tenant read/write denied لكل جدول ودور، خاصة viewer/collector/anon — منخفض-4 في تقرير RLS) — يوم إلى يومين.

### [مرحلة 2]
- **6.6** مراجعة منتجية لكشف `closing_balance` عبر رمز تحقق عام (قرار: إبقاء مع حدود مشددة، أو طلب معرّف إضافي) — اجتماع قرار + تنفيذ.
- **6.7** ترحيل كامل من GET إلى POST في `verify-statement` وإزالة مسار GET المؤقت.
- **6.8** تقرير اختراق خارجي (pentest) لنقاط OTP والكشوف والرفع قبل الإعلان التجاري العام.

---

## 7. قائمة التحقق الأمنية النهائية (بوابة الإطلاق)

يجب أن تكون كل البنود ✔ قبل أي إطلاق:

**الأسرار**
- [ ] مفتاح OpenWA القديم مُبطل فعلياً عند المزود، وسجلات الاستخدام المسيء مراجعة وموثقة.
- [ ] `grep -r "owa_k1_\|99c44b07" .` على المستودع وتاريخ git يعيد صفر نتائج.
- [ ] `gitleaks` في CI أخضر، وقاعدة نمط OpenWA مضافة.
- [ ] كل أسرار الإنتاج في `supabase secrets` فقط؛ لا قيم افتراضية لأسرار في أي ملف TypeScript/Dart.

**OTP**
- [ ] لا توليد/تخزين/تحقق OTP في العميل؛ حذف `_activeOtps` وباب `123456`/`000000` الخلفي.
- [ ] الرموز مخزنة HMAC فقط، TTL 5 دقائق، 5 محاولات، cooldown 60 ثانية، سقف يومي لكل رقم.
- [ ] `bootstrap-user-contact` يرفض أي رقم بلا `phoneProofToken` صالح غير مستهلك.
- [ ] تفكيك APK تجريبي لا يكشف مفاتيح أو عناوين داخلية.

**التفويض**
- [ ] `generate-statement` بـ `statementId` يعيد 404 لغير الأطراف (اختبار تكامل موثق).
- [ ] مسار ملف PDF لا يحمل `verification_code`.
- [ ] إرفاق الملفات يتطلب دور كتابة (ليس قراءة) — مثبت بـ pgTAP للأدوار viewer/cashier/عميل.
- [ ] magic bytes مفحوصة؛ SVG مرفوض من كل الباقات.

**البنية التحتية**
- [ ] rate limit في `verify-statement` على IP غير قابل للتزوير + حد لكل رمز؛ اختبار تزوير موثق.
- [ ] CORS فشل مغلق؛ لا `"*"` في أي استجابة محملة ببيانات؛ `ALLOWED_ORIGIN` مضبوط لكل بيئة.
- [ ] `send-whatsapp-otp` و`verify-whatsapp-otp` مدرجتان صراحة في `config.toml` بضبط `verify_jwt` مقصود وموثق.
- [ ] إزالة `http://127.0.0.1:3000` من إعداد الإنتاج.

---

## 8. جدول الاعتماديات والتسلسل

```
1.1 (إبطال المفتاح) ──▶ 1.2 ──▶ 1.3 ──▶ 1.4
                        │
2.1 ──▶ 2.2 ──▶ 2.3 ◀───┘        (2.3 يحتاج 1.1 + 5.1 + 5.2)
           │     │
           └──▶ 2.4 ──▶ 2.5
3.1 ──▶ 3.2        (مستقل، يبدأ فوراً)
4.1 ──▶ 4.2        4.3 و4.4 مستقلتان
5.1 و5.2 مستقلتان ──▶ 5.3
```

**المسار الحرج (أطول سلسلة):** 1.1 → 2.1 → 2.2 → 2.4 → 2.5 ≈ 3–4 أيام عمل لفرد واحد؛ بالتوازي مع 3.x و4.x و5.x يمكن ضغط الإجمالي إلى **4–5 أيام عمل** بمهندسين اثنين.

**إجمالي الجهد التقديري:** ‏~45–55 ساعة هندسية (فوري: ~6س، مرحلة صفر: ~30س، مرحلة 1: ~10س، مرحلة 2: قرار + pentest خارجي).

---

*انتهت الخطة — لم يُعدَّل أي ملف في المشروع؛ الملف الوحيد المكتوب هو هذه الخطة.*
