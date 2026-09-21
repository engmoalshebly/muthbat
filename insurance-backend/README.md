# Mock Concord Insurance API (Demo Only)

خدمة Backend تجريبية مستقلة تحاكي رحلة Concord كاملة:

`Customer → Vehicle → Quote/Offers → Select → Order/Invoice → Payment → Policy`

> الأسعار والوثائق والمدفوعات تجريبية بالكامل وليست صادرة من Concord الحقيقي.
> هذه الخدمة معزولة عن إنتاج مُثبَت ولا يجوز نشرها للعامة.

## التشغيل السريع

```bash
cp .env.example .env
# عدّل كلمات السر في .env قبل إتاحة الخدمة للإنترنت
docker compose --profile demo up --build -d
```

بعد التشغيل:

- Swagger: `http://localhost:8000/api/docs/`
- OpenAPI JSON: `http://localhost:8000/api/schema/`
- Health: `http://localhost:8000/api/v1/health`
- Postman: استورد `docs/Mock-Concord.postman_collection.json`

أنشئ حساب Demo صراحة عبر `TEST_API_USERNAME` و`TEST_API_PASSWORD` في `.env`.
لا توجد بيانات دخول افتراضية.

## المصادقة

كل الواجهات، عدا health والتوثيق، تحتاج JWT:

```bash
curl -s http://localhost:8000/api/v1/auth/token \
  -H 'Content-Type: application/json' \
  -d '{"username":"DEMO_USER_FROM_SECRET_MANAGER","password":"DEMO_PASSWORD_FROM_SECRET_MANAGER"}'
```

خذ قيمة `access` وأرسلها في كل طلب:

```http
Authorization: Bearer YOUR_ACCESS_TOKEN
```

## الواجهات

| الوظيفة | Method | Endpoint | المدخل الأساسي |
|---|---|---|---|
| فحص الخدمة | GET | `/api/v1/health` | لا يوجد |
| إنشاء عميل | POST | `/api/v1/customers` | national_id, birth_date, phone, full_name? |
| جلب عميل | GET | `/api/v1/customers/{customer_id}` | — |
| إنشاء مركبة | POST | `/api/v1/vehicles` | customer_id, registration_type, plate_no, brand, model, year, vehicle_value |
| جلب مركبة | GET | `/api/v1/vehicles/{vehicle_id}` | — |
| توليد 3 عروض | POST | `/api/v1/quotes` | customer_id, vehicle_id |
| جلب عرض سعر | GET | `/api/v1/quotes/{quote_id}` | — |
| اختيار عرض | POST | `/api/v1/quotes/{quote_id}/select` | offer_id |
| إنشاء طلب وفاتورة | POST | `/api/v1/orders` | customer_id, vehicle_id, quote_id, offer_id + Idempotency-Key |
| جلب الطلب | GET | `/api/v1/orders/{order_id}` | — |
| حالة الطلب | GET | `/api/v1/orders/{order_id}/status` | — |
| جلب الفاتورة | GET | `/api/v1/invoices/{invoice_id}` | — |
| تحقق الدفع | GET | `/api/v1/invoices/{invoice_id}/payment-status` | — |
| نجاح دفع تجريبي | POST | `/api/v1/testing/payments/{invoice_id}/success` | — |
| فشل دفع تجريبي | POST | `/api/v1/testing/payments/{invoice_id}/fail` | — |
| إصدار الوثيقة | POST | `/api/v1/policies` | order_id |
| جلب الوثيقة | GET | `/api/v1/policies/{policy_id}` | — |

## تجربة الرحلة كاملة

ضع التوكن في متغير ثم نفّذ كل خطوة، واستبدل المعرّفات من الرد السابق:

```bash
BASE=http://localhost:8000
TOKEN='YOUR_ACCESS_TOKEN'

curl -s "$BASE/api/v1/customers" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{"national_id":"1234567890","birth_date":"1995-05-18","phone":"967777123456","full_name":"Mohammed Ahmed"}'

curl -s "$BASE/api/v1/vehicles" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{"customer_id":"CUS-XXXXXX","registration_type":"PRIVATE","plate_no":"12345","brand":"Toyota","model":"Prado","year":2022,"vehicle_value":85000}'

curl -s "$BASE/api/v1/quotes" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{"customer_id":"CUS-XXXXXX","vehicle_id":"VEH-XXXXXX"}'

curl -s "$BASE/api/v1/quotes/QUT-XXXXXX/select" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{"offer_id":"OFF-XXXXXX"}'

curl -s "$BASE/api/v1/orders" -H "Authorization: Bearer $TOKEN" -H 'Idempotency-Key: demo-order-001' -H 'Content-Type: application/json' -d '{"customer_id":"CUS-XXXXXX","vehicle_id":"VEH-XXXXXX","quote_id":"QUT-XXXXXX","offer_id":"OFF-XXXXXX"}'

curl -s -X POST "$BASE/api/v1/testing/payments/INV-XXXXXX/success" -H "Authorization: Bearer $TOKEN"

curl -s "$BASE/api/v1/invoices/INV-XXXXXX/payment-status" -H "Authorization: Bearer $TOKEN"

curl -s "$BASE/api/v1/policies" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{"order_id":"ORD-XXXXXX"}'
```

## الوصول من جهاز آخر أو الإنترنت

الـcontainer يستمع على `0.0.0.0:8000`. من جهاز داخل الشبكة استخدم `http://SERVER_IP:8000`. للوصول العام افتح TCP/8000 في جدار الخادم، أو الأفضل ضع Caddy/Nginx أمام الخدمة مع HTTPS واضبط:

```env
DJANGO_DEBUG=false
DJANGO_ALLOWED_HOSTS=api.example.com
PUBLIC_BASE_URL=https://api.example.com
```

ثم اربط DNS بالخادم. لا تُعرّض بيانات الاختبار الافتراضية للإنترنت. رابط عام فعلي لا يمكن إنشاؤه دون خادم/نطاق أو حساب منصة نشر.

## قواعد العمل المطبقة

- لا يمكن إنشاء Order قبل اختيار Offer تابع لنفس Quote.
- Order وInvoice يُنشآن داخل transaction واحدة.
- `Idempotency-Key` إلزامي لإنشاء Order؛ إعادة نفس الطلب تعيد نفس Order.
- فشل الدفع يبقي Order في `PENDING_PAYMENT` وتبقى إعادة المحاولة ممكنة.
- لا تصدر Policy إلا إذا كانت Invoice وOrder مدفوعتين.
- إصدار Policy مكرر يعيد نفس الوثيقة بدل إنشاء أخرى.
- يحفظ Order نسخة `offer_snapshot` حتى لا يتغير السعر المقبول لاحقًا.

## الاختبارات

```bash
docker compose run --rm insurance-api python manage.py test
```
