# خطة إعادة بناء نظام المصادقة — «مُثبَت | MUTHBAT»

**الدور:** مخطط_إصلاح_المصادقة (Auth System Remediation Architect)
**النطاق:** إعادة بناء كاملة لطبقة المصادقة: Supabase Auth + OTP واتساب خادمي، إدارة الجلسة، فصل البيئات، ترحيل المستخدمين التجريبيين.
**المرجعية:** `analysis-reports/07-mobile-data-layer.md` (ملاحظات ح-3، ح-4، ح-5، ح-6، ع-4، ع-5، ع-8، م-4، م-5، خ-4) و`analysis-reports/08-api-contracts.md` (ملاحظات C-9، C-10، C-11، M-7، L-3، H-1).
**الحكم الحالي:** المصادقة الحالية كسر أمني كامل (كودا التفاف ثابتان، تحقق OTP في العميل، دخول بديل من الكاش، جلسة بلا توكن، هويات وهمية) — **يُحظر الإطلاق قبل إتمام مرحلة صفر من هذه الخطة.**

---

## 1. الملخص التنفيذي والقرارات المعمارية المحسومة

### القرار 1 — قناة OTP: Twilio Verify (قناة WhatsApp) ضمن Supabase Phone Auth، وليس OpenWA ولا توليد OTP مخصص

**الخيارات:**

| الخيار | الوصف | التقييم |
|---|---|---|
| **أ. Supabase Phone Auth + Twilio Verify (WhatsApp channel)** | تفعيل `auth.sms` في Supabase مع مزوّد Twilio Verify مهيأ على قناة واتساب. العميل يستدعي `signInWithOtp(phone:)` و`verifyOTP()` الأصليين. | ✅ **التوصية** — جلسات وتوكنات وتحديث تلقائي أصلية، RLS يعمل فوراً، قوالب واتساب معتمدة من Meta، لا كود OTP مخصص نصونه. |
| ب. OTP مخصص خادمي عبر OpenWA + Edge Function تصدر جلسات | تطوير `send-whatsapp-otp` لتوليد/تخزين/تحقق الرمز خادمياً ثم سكّ جلسة عبر Admin API. | ❌ سكّ جلسات مخصص (custom JWT / magiclink pseudo-email) هش ويحمل مسؤولية أمنية دائمة؛ OpenWA self-hosted بقايا تطوير (`whatsapp_otp_service.dart:32-36` عناوين LAN). |
| ج. إبقاء OpenWA مع إصلاحات طفيفة | نقل المفتاح للسيرفر فقط. | ❌ لا يحل جوهر المشكلة: التحقق في العميل وغياب جلسة Supabase حقيقية. |

**الحسم:** الخيار **أ**. المبرر: `config.toml:59-61` يعطّل `auth.sms` عمداً «حتى يُهيأ مزوّد إنتاج» — أي أن المعمارية الخلفية مصممة أصلاً لمسار Supabase Phone Auth الأصلي، والحل هو إكمال هذا المسار لا بناء مسار موازٍ. التحقق الأصلي يعني أن `auth.users.phone_confirmed_at` يُضبط من Supabase نفسه، وهو ما تعتمد عليه `bootstrap-user-contact` (`index.ts:14` ترفض إن لم يكن `user.phone` موثقاً).

### القرار 2 — تخزين `user_type`: عمود رسمي في `profiles` عبر migration جديدة، يملؤه التريجر من `raw_user_meta_data`

**الخيارات:** (أ) إضافة عمود `user_type` لجدول `profiles`؛ (ب) الاكتفاء بـ `raw_user_meta_data` في `auth.users` وقراءته من JWT.

**الحسم:** الخيار **أ**. المبرر: العميل يحتاج قراءة نوع المستخدم عبر PostgREST/RLS للتوجيه بين واجهتي التاجر والعميل، والواجهة تقرأه اليوم من `profiles` (`auth_controller.dart:119`) لكن العمود غير موجود (C-11). الاعتماد على JWT claim وحده يمنع الاستعلامات المستقبلية (تقارير، دعم فني) ويصعّب تغيير النوع لاحقاً. الهاتف **لا** يُضاف لـ `profiles` — يبقى في `auth.users.phone` ونسخته المشفرة في `private.customer_contacts` عبر `bootstrap-user-contact`.

### القرار 3 — الجلسة الوحيدة المعتمدة هي جلسة Supabase (PKCE + refresh token)؛ حذف مسار SharedPreferences بالكامل

لا خيار هنا: `_checkExistingSession` (`auth_controller.dart:71-94`) تُحذف وتُستبدل بـ `Supabase.instance.client.auth.currentSession` + مستمع `onAuthStateChange`. مفاتيح `cached_user_id/cached_user_type/cached_display_name/cached_phone` (`auth_controller.dart:176-180, 271-276, 464-469`) تُحذف نهائياً — يجوز الاحتفاظ بـ `cached_display_name` للعرض التجميلي فقط، غير الموثوق أمنياً.

### القرار 4 — كلمة السر تبقى مطلوبة (OTP للتحقق من ملكية الهاتف، كلمة السر للدخول اليومي)

نموذج الهوية النهائي: **الهاتف = الهوية، OTP واتساب = إثبات الملكية عند التسجيل/الاسترداد، كلمة السر = عامل الدخول الدائم**. هذا يطابق `signUp(phone:, password:)` و`signInWithPassword(phone:, password:)` المستخدمين أصلاً في الكود، ويبسّط الاسترداد (OTP → جلسة → `updateUser(password:)`).

---

## 2. المعمارية النهائية

```
┌──────────────────────────── Flutter Client ────────────────────────────┐
│  AuthController (StateNotifier)                                        │
│   ├─ مصدر الحقيقة الوحيد: Supabase.auth.currentSession / onAuthStateChange │
│   ├─ لا تخزين لهوية في SharedPreferences                               │
│   └─ user_type يُقرأ من public.profiles (SELECT عبر RLS)               │
└──────────────┬───────────────────────────────────────┬─────────────────┘
               │ supabase_flutter (PKCE)               │ functions.invoke
               ▼                                       ▼
┌──────────────── Supabase Cloud (per-env project) ──────────────────────┐
│  GoTrue (Auth)                                                         │
│   ├─ Phone Auth مفعّل: signUp / signInWithPassword / signInWithOtp     │
│   ├─ SMS Provider = Twilio Verify (WhatsApp channel)                   │
│   └─ JWT (access 1h) + refresh token — تحديث تلقائي من SDK            │
│                                                                        │
│  Postgres                                                              │
│   ├─ trigger on_auth_user_created → private.handle_new_auth_user()     │
│   │     ينشئ profiles(id, display_name, user_type) + customers(user_id)│
│   ├─ profiles.user_type (جديد، check in ('merchant','customer'))       │
│   └─ private.customer_contacts (هاتف مشفّر + hash) — خدمة فقط         │
│                                                                        │
│  Edge Functions                                                        │
│   └─ bootstrap-user-contact (موجودة، verify_jwt=true):                 │
│        تُستدعى مرة واحدة بعد أول تحقق OTP ناجح لتسجيل الهاتف المشفّر   │
│        في private.customer_contacts → تفعيل customer-directory         │
└────────────────────────────────────────────────────────────────────────┘
               ▲
               │ Twilio Verify API (قناة WhatsApp — قالب معتمد من Meta)
┌────────────┴───────────┐
│  Twilio Verify Service │
└────────────────────────┘
```

### كيف يرتبط رقم الهاتف بالمستخدم

1. `signUp(phone: '+9677XXXXXXX', password:, data: {display_name, user_type})` → صف في `auth.users` بـ `phone` غير موثق بعد.
2. Supabase يرسل OTP عبر Twilio Verify (واتساب) → العميل يستدعي `verifyOTP(phone:, token:, type: OtpType.signup)` → يُضبط `phone_confirmed_at` وتُنشأ جلسة.
3. التريجر `handle_new_auth_user` (`migrations/202607120002_functions_and_triggers.sql:114-143`) أنشأ فوراً `profiles` و`customers` — **يُوسَّع لملء `user_type` من `raw_user_meta_data`** (الخطوة 3.2).
4. العميل يستدعي `functions.invoke('bootstrap-user-contact')` مرة واحدة بعد التحقق → الدالة (`bootstrap-user-contact/index.ts:13-28`) تقرأ `user.phone` الموثق من JWT، تجد `customers` المرتبط، وتخزّن الهاتف مشفّراً + hash في `private.customer_contacts` عبر `service_upsert_customer_contact` (الممنوحة لـ `service_role` فقط — `202607120003_rls_and_grants.sql:87-89`). هذا هو **الربط الوحيد** بين الهاتف والهوية، ويبقى الهاتف الصريح خارج أي جدول عام.

### دور `bootstrap-user-contact` في المعمارية

- **متى:** بعد أول `verifyOTP` ناجح (تسجيل جديد)، وبعد أول دخول ناجح لأي حساب قائم لم يُسجَّل هاتفه بعد (idempotent — upsert).
- **لماذا:** تفعيل `customer-directory` (البحث عن عميل بهاش الهاتف) وربط العملاء بالتجار عبر الهاتف — الميزة التي وصفها تقرير 08 (H-1) بأنها «عديمة الجدوى» حالياً لأن أحداً لا يستدعيها.
- **لا تغيير جوهري في كود الدالة** — التغيير هو استدعاؤها من العميل أخيراً.

---

## 3. مخطط التدفق الكامل (State Machine)

### 3.1 التسجيل (Register)

```
RegisterScreen → validate(name, phone, password≥8, type)
  → AuthController.registerStart(name, phone, password, userType)
    → Supabase.auth.signUp(phone, password, data:{display_name, user_type})
       · نجاح → AuthStatus.otpSent (يُخزن phone فقط — لا كلمة سر في الحالة)
       · AuthApiException(phone exists) → خطأ «الرقم مسجل، سجّل دخولك أو استعد حسابك»
  → OtpVerificationScreen → AuthController.verifySignupOtp(code)
    → Supabase.auth.verifyOTP(phone, token, type: signup)
       · نجاح → جلسة نشطة →
         1) functions.invoke('bootstrap-user-contact')
         2) إن merchant: rpc('create_business', {p_name, p_business_type, p_currency_code:'YER', p_country_code:'YE', p_city, p_address:''})
            (يحل محل إنشاء biz-* المحلي — يحتاج شاشة إعداد محل أولى: مرحلة 1)
         3) AuthStatus.authenticated → توجيه حسب profiles.user_type
       · فشل → رسالة «رمز غير صحيح/منتهٍ» مع عداد محاولات من السيرفر
```

### 3.2 الدخول (Login)

```
LoginScreen → AuthController.loginWithPassword(phone, password)
  → Supabase.auth.signInWithPassword(phone:, password:)
     · نجاح → قراءة profiles (display_name, user_type) عبر RLS
              → bootstrap-user-contact (idempotent) → authenticated
     · AuthApiException(invalid credentials) → خطأ صريح — بلا أي fallback محلي
     · SocketException (لا شبكة) → «لا يوجد اتصال» — لا دخول أوفلاين بحساب غير موثق
```

### 3.3 استرداد الحساب (Recovery)

```
AccountRecoveryScreen → AuthController.sendRecoveryOtp(phone)
  → Supabase.auth.signInWithOtp(phone:)  (OTP عبر واتساب/Twilio)
  → OtpVerificationScreen (وضع recovery) → verifyOTP(type: sms)
     · نجاح → جلسة نشطة → شاشة «كلمة سر جديدة» (جديدة — مرحلة صفر)
       → Supabase.auth.updateUser(password: newPassword) → authenticated
```

### 3.4 استعادة الجلسة عند فتح التطبيق

```
main() → Supabase.initialize (PKCE — موجود في main.dart:20-26)
AuthController() → final session = Supabase.auth.currentSession
  · session != null && !session.isExpired → authenticated (قراءة profiles)
  · null/منتهية ولم يُحدَّث refresh → AuthStatus.initial → شاشة الدخول
+ اشتراك دائم: onAuthStateChange:
  · tokenRefreshed/signedIn → تحديث الحالة
  · signedOut → مسح الحالة + إيقاف SyncEngine
```

### 3.5 الخروج (Sign Out)

```
AuthController.signOut()
  1) فحص طابور المزامنة: إن وُجدت عمليات pending → حوار تحذير صريح
     «لديك N عملية غير مُرسلة» مع خياري [مزامنة الآن] / [خروج مع فقدانها]
  2) Supabase.auth.signOut() (إبطال refresh token خادمياً)
  3) مسح حالة AuthController فقط
  4) AppDatabase.clearAll() فقط بعد تأكيد المستخدم في الحوار أعلاه
     (يحل ع-5: فقدان بيانات مالية صامت — auth_controller.dart:505)
```

---

## 4. التغييرات المطلوبة في كل ملف (يُحذف / يُضاف)

### 4.1 `mobile/lib/core/services/whatsapp_otp_service.dart` — **حذف الملف كاملاً (252 سطراً)**

| يُحذف | المرجع |
|---|---|
| `sessionId` و`apiKey` المضمّنان نصياً | أسطر 28-29 (ح-6 / C-10) |
| عناوين LAN/localhost | أسطر 32-36 |
| كودا الالتفاف `123456`/`000000` | أسطر 196-199 (ح-3) |
| توليد/تخزين/مقارنة OTP في العميل (`_activeOtps`, `generateOtpCode`, `verifyOtp`) | أسطر 39, 95-99, 188-251 |
| قراءة `custom_openwa_base_url` من SharedPreferences | أسطر 53-60 |

**يُضاف بدله:** لا شيء — الإرسال والتحقق يصبحان `Supabase.auth.signInWithOtp` / `verifyOTP`. تُحذف الحزمة من أي import، ويُحذف `custom_openwa_base_url` من أي شاشة إعدادات.

### 4.2 `mobile/lib/features/auth/presentation/controllers/auth_controller.dart` — إعادة كتابة شبه كاملة

| يُحذف | المرجع |
|---|---|
| حقل `mockOtpCode` وقيمته الافتراضية `'123456'` | أسطر 25, 36 (ح-3) |
| حقل `pendingPassword` (كلمة سر صريحة في الذاكرة) | سطر 22 (ع-8) — التسجيل يتم بـ `signUp` **قبل** OTP فلا حاجة لتعليقها |
| `_checkExistingSession` من SharedPreferences | أسطر 71-94 (ح-5) |
| fallback الكاش المحلي في `loginWithPassword` | أسطر 128-138 (ح-4 / C-9) |
| توليد `usr-<phone>` | أسطر 104, 214, 389 (خ-4) |
| إنشاء `biz-<userId>` محلياً | أسطر 155, 254, 444 (C-9) |
| `profiles.upsert` بأعمدة `user_type`/`phone` | أسطر 230-235, 416-421 (C-11 / ع-4) |
| الاستعلام `select('display_name, user_type')` قبل وجود العمود | أسطر 117-121 (M-7) — يعود بعد migration العمود |
| قبول `enteredCode != state.mockOtpCode` كمسار نجاح | سطر 397 (ح-3) |
| `signInWithOtp` الموازي الميت | أسطر 355-360 (م-4) — يصبح هو المسار الوحيد |
| استدعاء `WhatsAppOtpService` | أسطر 310-313, 348-351, 392-395 |
| `AppDatabase.instance.clearAll()` الصامت عند الخروج | سطر 505 (ع-5) |
| كتابة مفاتيح `cached_*` في SharedPreferences | أسطر 176-180, 271-276, 464-469 (ح-5) |

| يُضاف | الوظيفة |
|---|---|
| `_initFromSupabaseSession()` | استعادة الجلسة من `currentSession` + `onAuthStateChange` (§3.4) |
| `registerStart()` | `signUp` مع `data:{display_name, user_type}` — قبل OTP |
| `verifySignupOtp(code)` | `verifyOTP(type: signup)` ثم `bootstrap-user-contact` ثم `create_business` للتاجر |
| `loginWithPassword()` (مُعاد) | `signInWithPassword` بلا أي fallback؛ أخطاء مميزة (بيانات خاطئة/شبكة/حظر) |
| `sendRecoveryOtp()` / `verifyRecoveryOtp()` / `completePasswordReset(newPassword)` | مسار §3.3 |
| `_loadProfile()` | قراءة `display_name, user_type` من `profiles` عبر RLS |
| `signOut()` (مُعاد) | تحذير الطابور + `auth.signOut()` + مسح الحالة (§3.5) |
| حقل `pendingAction` في `AuthState` | لتمييز سياق شاشة OTP: `signup` / `recovery` (بدل `isNewUser` + `pendingPassword`) |

### 4.3 `mobile/lib/core/config/supabase_config.dart` — إعادة كتابة (50 سطراً → ~40)

| يُحذف | المرجع |
|---|---|
| قراءة `custom_supabase_url` / `custom_supabase_anon_key` من SharedPreferences | أسطر 26-28, 45-48 (ح-6) |
| `updateCredentials()` كاملة | أسطر 36-49 |
| `offline_mock_mode` وقراءته | أسطر 17, 29 (م-5) — يُحذف أيضاً استخداماه في `sync_engine.dart:109,148` و`merchant_repository.dart:280` |
| مفتاح anon الوهمي الافتراضي | أسطر 12-13 (L-3) |

| يُضاف | الوظيفة |
|---|---|
| `String.fromEnvironment('SUPABASE_URL')` / `SUPABASE_ANON_KEY` / `APP_ENV` | إعداد build-time عبر `--dart-define` (§6) |
| `assert(url.isNotEmpty)` في وضع release | فشل مبكر واضح بدل الاتصال بـ `127.0.0.1` في الإنتاج |

### 4.4 `mobile/lib/main.dart`

- إبقاء `Supabase.initialize` (أسطر 20-26) مع تمرير قيم `fromEnvironment`، وإضافة `debug: kDebugMode` وضبط `localStorage` على التخزين الآمن الافتراضي للحزمة (لا SharedPreferences صريحة للجلسة).
- **إزالة `try/catch` البلع** حول `Supabase.initialize` (أسطر 19-29): في الإنتاج فشل التهيئة = شاشة خطأ فادح، لا متابعة صامتة.

### 4.5 الشاشات

| الملف | يُحذف | يُضاف |
|---|---|---|
| `screens/otp_verification_screen.dart` | زر «تعبئة رمز بيئة التطوير» ودالة `_fillDefaultMockCode` (أسطر 146-151, 425-435) وكل إشارة لـ `mockOtpCode` | تمرير سياق `pendingAction` (signup/recovery)؛ رسالة محاولات متبقية من خطأ السيرفر |
| `screens/login_screen.dart` | حد كلمة السر الأدنى 4 خانات (سطر 54) | حد أدنى 8 خانات؛ تمييز خطأ «لا اتصال» عن «بيانات خاطئة» |
| `screens/register_screen.dart` | حد 4 خانات (سطر 69) ومؤشر القوة الذي يكافئ 4 خانات (سطر 120) | حد 8 خانات + تحديث عتبات المؤشر؛ الموافقة على الشروط تبدأ `false` (سطر 30 `_agreedToTerms = true` حالياً — موافقة صورية) |
| `screens/account_recovery_screen.dart` | الاكتفاء بإرسال OTP ثم دخول كامل (التدفق الحالي يمنح جلسة دون إعادة تعيين كلمة سر) | بعد نجاح OTP → شاشة جديدة `reset_password_screen.dart` (كلمة سر جديدة + تأكيدها → `updateUser`) |

### 4.6 الباكند

| الملف | التغيير |
|---|---|
| `supabase/config.toml` | `[auth.sms] enable_signup = true` + `enable_confirmations = true`؛ مقطع `[auth.sms.twilio_verify]` (account_sid / auth_token / message_service_sid من أسرار البيئة)؛ إبقاء `jwt_expiry = 3600` (سطر 49) و`enable_anonymous_sign_ins = false` (سطر 51) |
| migration جديدة `..._profiles_user_type.sql` | `alter table public.profiles add column user_type text not null default 'customer' check (user_type in ('merchant','customer'));` + منحة `update` لا تشمل `user_type` (يبقى من التريجر فقط) + backfill من `raw_user_meta_data` |
| `202607120002_functions_and_triggers.sql` (عبر migration جديدة، لا تعديل بأثر رجعي) | توسيع `handle_new_auth_user` (أسطر 114-138) ليملأ `user_type` من `new.raw_user_meta_data ->> 'user_type'` مع افتراض `'customer'` |
| `functions/send-whatsapp-otp/` | **حذف الدالة** بعد الانتقال لـ Twilio Verify (تلغي الحاجة لها ولأسرار OpenWA `index.ts:3-5`)، أو تجميدها معطلة خارج النشر. إزالة إعدادها من `config.toml` إن وُجد |
| اختبارات pgTAP جديدة | اختبار التريجر (إنشاء profile بـ user_type صحيح)، اختبار منع update `user_type` من `authenticated` |

---

## 5. إدارة الجلسة والتوكن

1. **التخزين:** `supabase_flutter` مع `AuthFlowType.pkce` (موجود `main.dart:23-25`) يخزّن الجلسة في التخزين الآمن للمنصة (Keychain/Keystore) — لا SharedPreferences يدوية إطلاقاً.
2. **التحديث:** SDK يحدّث access token تلقائياً قبل انتهائه (`jwt_expiry = 3600`). لا كود تحديث يدوي.
3. **الانتهاء النهائي:** إذا فشل refresh (إبطال خادمي/انقطاع طويل) → حدث `signedOut` في `onAuthStateChange` → العودة لشاشة الدخول مع رسالة «انتهت الجلسة، سجّل دخولك مجدداً».
4. **الأوفلاين:** جلسة صالحة غير منتهية تسمح بالعمل أوفلاين (قراءة/تأليف قيود في الطابور) — لكن **لا إنشاء حساب ولا دخول أول ولا تحقق OTP أوفلاين**.
5. **تعدد الأجهزة:** كل جهاز جلسة مستقلة؛ خروج جهاز لا يبطل الآخر. (مرحلة 2: شاشة «الأجهزة النشطة» عبر `auth.admin` — خارج النطاق الآن.)
6. **RLS:** كل استدعاءات RPC/SELECT تعتمد `auth.uid()` — بلا جلسة حقيقية لا بيانات، وهذا هو الضمان الذي كان غائباً.

---

## 6. فصل البيئات dev / staging / prod

| البيئة | مشروع Supabase | آلية الحقن | OTP |
|---|---|---|---|
| dev | `supabase start` محلي (`127.0.0.1:55321`) | `--dart-define=APP_ENV=dev` + مفاتيح CLI المحلية | أرقام اختبار Twilio Verify (verify sid بوضع test) — بلا رسائل حقيقية |
| staging | مشروع سحابي مستقل `muthbat-staging` | `--dart-define` من CI secrets | Twilio Verify حقيقي على أرقام الفريق فقط |
| prod | مشروع سحابي `muthbat-prod` | `--dart-define` من CI secrets، **يُمنع** بقاء أي قيمة افتراضية | Twilio Verify إنتاجي (قالب واتساب معتمد من Meta) |

- ملف `mobile/lib/core/config/env.dart` جديد: `enum AppEnv { dev, staging, prod }` + `EnvConfig.current` من `APP_ENV`، و`assert` يمنع `APP_ENV=dev` في `kReleaseMode`.
- أسرار Twilio/OpenWA تُدار عبر `supabase secrets set` لكل مشروع — **لا شيء في الكود**.
- حذف أي شاشة/إعداد يسمح للمستخدم بتغيير عنوان Supabase من داخل التطبيق (`supabase_config.dart:36-49`).

---

## 7. ترحيل المستخدمين التجريبيين الحاليين

**تشخيص:** الحسابات الحالية بمعظمها محلية بحتة (`usr-*/biz-*` لم تصل السيرفر — C-9)، وأي حسابات وصلت `auth.users` أُنشئت بمسارات ملتفة وبيانات وصفية ناقصة، ولا توجد بيانات مالية مزامَنة مرتبطة بها (تقرير 07 ح-1: كل RPC يفشل أصلاً).

1. **جرد (مرحلة صفر):** استعلام admin على `auth.users` في مشروع staging/prod: عدد المستخدمين، تواريخ الإنشاء، وجود `phone_confirmed_at`. النتيجة المتوقعة: صفر أو عدد اختباري ضئيل.
2. **القرار المحسوم — مسح كامل (Clean Slate):** حذف كل صفوف `auth.users` التجريبية عبر Admin API (تتبعها cascades إلى `profiles`/`customers`). **المبرر:** لا بيانات مالية مزامَنة تُفقد (المزامنة لم تنجح قط)، وإصلاح هويات مفبركة أخطر من إعادة تسجيلها، والقاعدة لم تُطلق تجارياً بعد.
3. **الأجهزة:** إصدار أول بناء بالمصادقة الجديدة يرفع `_dbVersion` مع `onUpgrade` يمسح SQLite وSharedPreferences القديمة (مفاتيح `cached_*` و`custom_supabase_*` و`custom_openwa_base_url`) في التشغيل الأول — رسالة واحدة للمختبرين: «أعد تسجيل حسابك».
4. **توثيق:** سجل في `fix-plan` بأسماء/أرقام الحسابات المحذوفة وتاريخه (أثر تدقيقي).
5. **لا يوجد مسار ترحيل بيانات** — لأنه لا توجد بيانات خادمية ذات قيمة. إن ظهر في الجرد حساب حقيقي له قيود مزامَنة فعلاً (مستبعد)، يُستثنى ويُعالج يدوياً بإعادة إصدار كلمة سر عبر Admin + إجبار تحقق OTP.

---

## 8. الخطوات التنفيذية المرقمة

> الجهد بوحدة «يوم-مهندس» (ي.م). الاعتماديات بأرقام الخطوات.

### [فوري — خلال 24 ساعة]

| # | الملف المستهدف | التغيير | معيار التحقق | الاعتماديات | الجهد |
|---|---|---|---|---|---|
| 0.1 | `mobile/lib/core/services/whatsapp_otp_service.dart` | حذف شرط قبول `123456`/`000000` (أسطر 196-199) وحذف قبول `mockOtpCode` في `auth_controller.dart:397` — رقعة ساخنة قبل أي إعادة بناء | فحص يدوي: إدخال `123456` في شاشة OTP يفشل دائماً | — | 0.25 ي.م |
| 0.2 | `auth_controller.dart:128-138` | تعطيل fallback الكاش في `loginWithPassword` (رمي الخطأ بدل الدخول المحلي) | كلمة سر خاطئة لرقم موجود في الكاش → رفض دخول | — | 0.25 ي.م |
| 0.3 | `auth_controller.dart:71-94` | تعطيل `_checkExistingSession` المعتمد على SharedPreferences (التطبيق يفتح على شاشة الدخول مؤقتاً) | حذف `cached_user_id` يدوياً ثم فتح التطبيق → شاشة دخول | — | 0.25 ي.م |
| 0.4 | — | تدوير مفتاح OpenWA المسرّب (`whatsapp_otp_service.dart:29` و`send-whatsapp-otp/index.ts:5`) واعتباره مكشوفاً | المفتاح القديم مرفوض من بوابة OpenWA | — | 0.25 ي.م |

### [مرحلة صفر — يحظر الإطلاق]

| # | الملف المستهدف | التغيير | معيار التحقق | الاعتماديات | الجهد |
|---|---|---|---|---|---|
| 1.1 | حساب Twilio + `supabase/config.toml` | إنشاء Twilio Verify Service بقناة WhatsApp، اعتماد قالب Meta، ضبط `[auth.sms]` + `[auth.sms.twilio_verify]` وتفعيل `enable_signup` | `supabase start` محلياً + رقم اختبار Twilio → وصول OTP على واتساب | 0.4 | 1 ي.م |
| 1.2 | migration جديدة `profiles_user_type` | إضافة العمود + check constraint + backfill + توسيع `handle_new_auth_user` | pgTAP: تسجيل مستخدم بـ `user_type='merchant'` → صف `profiles` بالقيمة نفسها؛ محاولة `update user_type` من دور `authenticated` تفشل | — | 1 ي.م |
| 1.3 | `supabase_config.dart` + `env.dart` + `main.dart` | إعادة كتابة الإعداد: `fromEnvironment`، حذف SharedPreferences overrides و`offline_mock_mode` | بناء release بلا dart-define يفشل بـ assert واضح؛ لا وجود لـ `custom_supabase_url` في الكود | — | 0.5 ي.م |
| 1.4 | `auth_controller.dart` | إعادة كتابة كاملة وفق §4.2 (حذف كل مسارات الالتفاف + `signUp`/`verifyOTP`/`signInWithPassword`/`updateUser` + `onAuthStateChange`) | اختبار تكامل: تسجيل→OTP→جلسة→`profiles.user_type` صحيح؛ دخول بكلمة خاطئة → رفض؛ إغلاق وفتح التطبيق → جلسة مستعادة من SDK | 1.1, 1.2, 1.3 | 2 ي.م |
| 1.5 | `whatsapp_otp_service.dart` | حذف الملف نهائياً + تنظيف imports | `flutter analyze` نظيف؛ بحث `WhatsAppOtpService` = صفر | 1.4 | 0.25 ي.م |
| 1.6 | الشاشات الأربع + `reset_password_screen.dart` جديدة | تعديلات §4.5 (حد 8 خانات، حذف زر التعبئة، شاشة إعادة التعيين، الموافقة تبدأ false) | تدفق recovery كامل: OTP → كلمة سر جديدة → دخول بالجديدة | 1.4 | 1 ي.م |
| 1.7 | استدعاء `bootstrap-user-contact` | في `AuthController` بعد أول تحقق ناجح وعند أول دخول لحساب قديم | صف جديد في `private.customer_contacts` بـ hash/تشفير صحيحين؛ `customer-directory` يجد الرقم | 1.4 | 0.5 ي.م |
| 1.8 | `functions/send-whatsapp-otp` | حذف/تعطيل الدالة وأسرار OpenWA من مشاريع staging/prod | `supabase functions list` لا تعرضها؛ بحث `OPENWA_` في secrets = صفر | 1.1 | 0.25 ي.م |
| 1.9 | `auth_controller.dart:505` + حوار الخروج | حذف `clearAll()` الصامت؛ حوار تحذير طابور المزامنة (§3.5) | خروج مع عمليات pending → تحذير؛ خروج بطابور فارغ → بلا حوار | 1.4 | 0.5 ي.م |
| 1.10 | ترحيل المستخدمين التجريبيين | تنفيذ §7 (جرد + مسح + مسح أول تشغيل) | `auth.users` في prod فارغ قبل التجريبي المغلق؛ سجل الحذف موثق | 1.2 | 0.5 ي.م |
| 1.11 | اختبارات | اختبارات وحدة لـ AuthController (موّcks لـ Supabase) + اختبار تكامل e2e لتدفقي التسجيل والدخول على staging | CI أخضر؛ تغطية مسارات الخطأ (OTP خاطئ/منتهٍ، بلا شبكة، رقم مكرر) | 1.4, 1.6 | 1.5 ي.م |

### [مرحلة 1 — تجريبي مغلق]

| # | الملف المستهدف | التغيير | معيار التحقق | الاعتماديات | الجهد |
|---|---|---|---|---|---|
| 2.1 | شاشة إعداد المحل الأولى | بعد تسجيل تاجر: إدخال اسم المحل/المدينة/العملة → `rpc('create_business', ...)` (يحل محل `biz-*` النهائي ويربط C-8/`create_business` غير المستدعاة) | محل يظهر في `businesses` و`business_members` بدور owner | 1.4 | 1.5 ي.م |
| 2.2 | rate limiting إضافي | سياسات حدود على إرسال OTP (مزوّد Twilio + حدود Supabase) + حظر مؤقت بعد 5 محاولات تحقق فاشلة | 6 محاولات OTP خاطئة → قفل مؤقت برسالة واضحة | 1.1 | 0.5 ي.م |
| 2.3 | رسائل أخطاء مصنفة | خريطة `AuthApiException` → رسائل عربية دقيقة (خ-5) | كل حالة خطأ لها رسالة مميزة موثقة | 1.4 | 0.5 ي.م |
| 2.4 | `flutter_secure_storage` صريح + حماية الجهاز | التأكد من تخزين الجلسة في Keystore/Keychain، وكشف root/jailbreak مع تحذير | فحص أمني: لا tokens في SharedPreferences/الملفات | 1.4 | 1 ي.م |

### [مرحلة 2 — إطلاق تجاري]

| # | الملف المستهدف | التغيير | معيار التحقق | الاعتماديات | الجهد |
|---|---|---|---|---|---|
| 3.1 | مراقبة وتنبيهات | لوحة أحداث auth (معدل نجاح OTP، زمن التسليم، محاولات فاشلة/رقم) عبر سجلات Twilio + Supabase | تنبيه عند هبوط نجاح التسليم < 90% | 2.2 | 1 ي.م |
| 3.2 | قناة SMS احتياطية | تفعيل SMS كقناة سقوط عند فشل واتساب (نفس Twilio Verify) | تعطيل واتساب على جهاز اختبار → وصول SMS | 1.1 | 0.5 ي.م |
| 3.3 | مراجعة أمنية خارجية | اختبار اختراق لمسارات auth قبل الإطلاق العام | تقرير بلا نتائج حرجة/عالية | كل ما سبق | خارجي |

---

## 9. معايير التحقق النهائية (Definition of Done لمرحلة صفر)

1. **لا كود التفاف:** بحث شامل في `mobile/lib` عن `'123456'` و`'000000'` و`mockOtpCode` و`WhatsAppOtpService` و`cached_user_id` و`usr-` و`biz-` = صفر نتيجة (باستثناء سجلات/توثيق).
2. **لا دخول بلا جلسة:** أي حالة `authenticated` في التطبيق تقابلها جلسة Supabase حية (`currentSession != null`) — يُختبر بمسح التخزين الآمن وإعادة الفتح.
3. **OTP خادمي 100%:** تعطيل شبكة الجهاز بعد استلام الرمز لا يسمح بالتحقق؛ تعديل ذاكرة التطبيق لا يكشف أي رمز (لا رمز في العميل أصلاً).
4. **هوية ↔ هاتف:** لكل مستخدم جديد: `auth.users.phone_confirmed_at` مضبوط + صف `profiles` بـ `user_type` صحيح + صف `private.customer_contacts` بعد أول دخول.
5. **RLS فعّال:** استدعاء أي RPC من جلسة منتهية/ملغاة → 401؛ قراءة `profiles` لمستخدم آخر → مرفوضة.
6. **البيئات:** بناء release يحمل إعداد prod فقط؛ لا `127.0.0.1` ولا مفاتيح محلية في الحزمة (فحص strings على APK).
7. **الخروج:** لا فقدان صامت لطابور المزامنة؛ بعد الخروج وإعادة الدخول بحساب آخر لا تتسرب بيانات الحساب الأول.
8. **e2e أخضر على staging:** تسجيل تاجر + عميل، دخول، استرداد، خروج، استعادة جلسة — كلها آلياً في CI.

---

## 10. مخاطر وملاحظات تنفيذية

- **اعتماد قالب واتساب من Meta** قد يستغرق أياماً — يبدأ فوراً (خطوة 1.1) لأنه على المسار الحرج.
- توسيع `handle_new_auth_user` يتم عبر **migration جديدة** (`create or replace`) لا بتعديل ملف 0002 بأثر رجعي، حفاظاً على قابلية إعادة النشر.
- `customers` يُنشأ لكل مستخدم (تاجر أو عميل) — سلوك التريجر الحالي مقبول ومقصود (التاجر قد يكون عميلاً لدى تاجر آخر).
- إزالة `offline_mock_mode` تتطلب تنسيقاً مع خطة إصلاح المزامنة (ملف خطة آخر) لأن `sync_engine.dart:109,148` يعتمدانه — التنسيق موكول لمالك خطة المزامنة، وهذه الخطة تفترض حذفه.
- حذف `send-whatsapp-otp` يلغي حاجة OpenWA كلياً؛ إن قررت الإدارة الإبقاء على OpenWA كقناة بديلة مستقبلاً، تُعاد كتابتها من الصفر بنمط `_shared` الموحد (cors/auth/http) لا الكود الحالي.

---

*انتهت الخطة — مخطط_إصلاح_المصادقة. كل مرجع سطر قابل للتحقق في المسارات المذكورة.*
