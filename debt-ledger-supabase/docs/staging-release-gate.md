# بوابة بيئة Staging

المرحلة لا تصبح جاهزة بمجرد نجاح الاختبارات المحلية. يلزم مشروع Supabase مستقل،
مضيف OpenWA دائم، ورقما هاتف اختبار لا يحتويان بيانات حقيقية. لا تُنسخ أي أسرار
بين staging والإنتاج.

> **الوضع الحالي:** باختيار استخدام مشروع `muthbat` نفسه، يعامل المشروع
> `ylzzascthljvomzclorl` كبيئة الاختبار الحالية، وليس كإنتاج. لا توجد عزلة أو
> إمكانية ترقية مستقلة إلى الإنتاج؛ يلزم إنشاء مشروع إنتاج منفصل قبل الإطلاق.

## 1. ما جهزه المستودع

- `deploy/staging/deploy.sh`: يربط مشروع staging، يطبق جميع الترحيلات، يرفع
  إعداد Auth وجميع الأسرار، وينشر كل Edge Functions التشغيلية.
- النشر المعتاد **لا ينشر** `staging-direct-signup` ويشترط أن تكون قيمة
  `ALLOW_STAGING_DIRECT_AUTH=false`.
- `deploy/staging/verify-access.sh`: يفحص جاهزية OpenWA، رفض API بلا مفتاح،
  تعطيل التسجيل المباشر، ومنع anon من قراءة المتاجر.
- `OpenWA/docker-compose.staging.yml`: PostgreSQL دائم وملفات جلسة WhatsApp
  على volume دائم، مع ربط API الخام على loopback فقط.
- تطبيق staging يستخدم OTP افتراضياً. تجاوز OTP يحتاج علم بناء صريح
  `ALLOW_STAGING_DIRECT_AUTH=true` إضافة إلى تفعيل الدالة خادمياً.

## 2. إنشاء Supabase ونشره

أنشئ مشروعاً جديداً من لوحة Supabase وسجل `project ref` ومفتاح anon فقط في
مدير أسرارك. لا تضع service-role في التطبيق؛ Supabase يحقنه تلقائياً داخل Edge
Functions المستضافة.

إذا تقرر استخدام مشروع `muthbat` الحالي مؤقتاً، استخدم مرجعه
`ylzzascthljvomzclorl` ولا تنفذ اختبارات مدمرة أو `db reset` عليه.

```bash
cd debt-ledger-supabase
cp deploy/staging/.env.example deploy/staging/.env
# املأ القيم الحقيقية، ثم:
export SUPABASE_PROJECT_REF=xxxxxxxxxxxxxxxxxxxx
deploy/staging/deploy.sh
```

ولّد القيم بدلاً من كتابتها يدوياً، مثال: `openssl rand -hex 32`. يجب أن يكون
`PHONE_ENCRYPTION_KEY` مفتاح Base64 بطول 32 بايت (`openssl rand -base64 32`).
اجعل `OPENWA_BASE_URL` عنوان HTTPS يمكن لـ Supabase الوصول إليه، ولا تستخدم
localhost.

## 3. تشغيل OpenWA بصورة دائمة

على مضيف Linux مخصص:

```bash
cd OpenWA
cp staging.env.example .env
# استبدل كل replace-* وأبق المنافذ الخام على 127.0.0.1
docker compose --profile postgres -f docker-compose.yml -f docker-compose.staging.yml up -d --build
docker compose --profile postgres -f docker-compose.yml -f docker-compose.staging.yml ps
```

الإعداد الحالي يستخدم Caddy عبر `Caddyfile.staging` ويصدر TLS تلقائياً للنطاق
`openwa.217-216-79-195.sslip.io`، بينما يبقى `127.0.0.1:2785` داخلياً. اسمح
للعالم بالوصول إلى 80/443 فقط؛ يحمي `API_MASTER_KEY` نقاط الأعمال. لا تنشر dashboard:
ادخل إليه عبر VPN أو SSH tunnel مثل
`ssh -L 2785:127.0.0.1:2785 user@host`. أغلق 2785 و2886 و5432 في جدار
الحماية العام، وعطّل Swagger في staging.

أنشئ جلسة باسم قيمة `OPENWA_SESSION_ID`، امسح QR من هاتف الاختبار، وانتظر
حالة connected. بعد ذلك أعد تشغيل الحاويات وتأكد أن الحالة بقيت connected؛
الـ volume `openwa-data` يحفظ بيانات اعتماد WhatsApp و`postgres-data` يحفظ
بيانات الخدمة.

## 4. التسجيل المباشر الطارئ

لا تستخدمه في اختبار قبول OTP. إن تعطل WhatsApp وكان مطلوباً مؤقتاً لاختبار
وظائف أخرى فقط:

```bash
export SUPABASE_PROJECT_REF=xxxxxxxxxxxxxxxxxxxx
CONFIRM_STAGING_BYPASS=ENABLE_TEMPORARILY deploy/staging/enable-direct-signup.sh
# ابن تطبيقاً داخلياً بعلم ALLOW_STAGING_DIRECT_AUTH=true
# وبعد الاختبار مباشرة:
deploy/staging/disable-direct-signup.sh
```

## 5. اختبار القبول والحسابات

أنشئ حساب التاجر والعميل عبر مسار OTP الحقيقي في التطبيق، لا من SQL ولا من
service-role. سجّل أرقام الاختبار ومعرفات الحسابات في مدير الاختبار الخارجي،
ولا تضف كلمات المرور أو الهواتف إلى Git.

نفذ وسجّل التاريخ والنتيجة والدليل لكل بند:

1. طلب OTP لكل حساب ووصول الرسالة فعلياً عبر WhatsApp.
2. إدخال `000000` أو رمز خاطئ والتأكد من `invalid_otp` وعدم إنشاء حساب.
3. طلب رمز جديد، الانتظار أكثر من خمس دقائق، والتأكد من رفضه كمنتهي.
4. تكرار الطلب قبل 60 ثانية ثم تجاوز 5 طلبات للهاتف أو 10 للعنوان خلال ساعة؛
   يجب ظهور HTTP 429 مع `Retry-After`.
5. إدخال الرمز الصحيح مرة واحدة، ثم رفض إعادة استخدامه.
6. إعادة تشغيل OpenWA والتأكد أن جلسة WhatsApp لا تطلب QR جديداً.
7. تشغيل فحص الوصول:

```bash
export SUPABASE_URL=https://xxxxxxxxxxxxxxxxxxxx.supabase.co
export SUPABASE_ANON_KEY=...
export OPENWA_BASE_URL=https://openwa-api.staging.example.com
export OPENWA_API_KEY=...
deploy/staging/verify-access.sh
```

8. الدخول بالحسابين والتأكد أن العميل لا يرى بيانات التاجر وأن تاجراً آخر لا
   يرى متاجر أو عملاء أو قيود غير تابعة له.

أي فشل هو **No-Go**. احتفظ بلقطات/سجلات القبول خارج المستودع بعد إخفاء الهاتف
والرموز والمفاتيح.
