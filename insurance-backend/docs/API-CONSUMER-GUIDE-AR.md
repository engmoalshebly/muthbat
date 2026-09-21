# دليل استخدام Mock Concord Insurance API — Demo فقط

هذا المستند جاهز للإرسال إلى أي مطوّر أو فريق تكامل لاستخدام واجهة التأمين التجريبية.

## معلومات الاتصال

```text
Base URL: https://api.example.com
Swagger UI: https://api.example.com/api/docs/
OpenAPI Schema: https://api.example.com/api/schema/
Health Check: https://api.example.com/api/v1/health
Username: DEMO_USER_FROM_SECRET_MANAGER
Password: DEMO_PASSWORD_FROM_SECRET_MANAGER
```

هذه بيئة Mock للاختبار وليست Concord الحقيقية. الأسعار والدفعات والوثائق الناتجة تجريبية.

## صيغة الردود

الرد الناجح:

```json
{"success": true, "data": {}}
```

رد الخطأ:

```json
{"success": false, "error": {"status": 400, "details": {}}}
```

## 1. الحصول على JWT

```http
POST /api/v1/auth/token
Content-Type: application/json
```

```json
{
  "username": "DEMO_USER_FROM_SECRET_MANAGER",
  "password": "DEMO_PASSWORD_FROM_SECRET_MANAGER"
}
```

يرجع `access` و`refresh`. أرسل access مع بقية الطلبات:

```http
Authorization: Bearer ACCESS_TOKEN
```

لتجديده:

```http
POST /api/v1/auth/token/refresh
Content-Type: application/json

{"refresh":"REFRESH_TOKEN"}
```

## 2. إنشاء عميل

```http
POST /api/v1/customers
```

```json
{
  "national_id": "1234567890",
  "birth_date": "1995-05-18",
  "phone": "967777123456",
  "full_name": "Mohammed Ahmed"
}
```

احتفظ بـ`customer_id` من الرد. `national_id` فريد ولا يمكن تكراره.

جلب العميل:

```http
GET /api/v1/customers/{customer_id}
```

## 3. إنشاء مركبة

```http
POST /api/v1/vehicles
```

```json
{
  "customer_id": "CUS-XXXXXX",
  "registration_type": "PRIVATE",
  "plate_no": "12345",
  "brand": "Toyota",
  "model": "Prado",
  "year": 2022,
  "vehicle_value": 85000
}
```

احتفظ بـ`vehicle_id`. جلب المركبة:

```http
GET /api/v1/vehicles/{vehicle_id}
```

## 4. البحث عن عروض

```http
POST /api/v1/quotes
```

```json
{
  "customer_id": "CUS-XXXXXX",
  "vehicle_id": "VEH-XXXXXX"
}
```

يرجع `quote_id` وثلاثة عروض داخل `offers`. كل عرض يحتوي على `offer_id` واسم المنتج والسعر والتحمل والتغطية والعملة. صلاحية العرض 24 ساعة.

جلب Quote لاحقًا:

```http
GET /api/v1/quotes/{quote_id}
```

## 5. اختيار العرض

```http
POST /api/v1/quotes/{quote_id}/select
```

```json
{"offer_id":"OFF-XXXXXX"}
```

يجب إرسال `offer_id` نفسه الذي أعاده الخادم، وليس رقم ترتيب العرض.

## 6. إنشاء Order وInvoice

```http
POST /api/v1/orders
Idempotency-Key: UNIQUE-VALUE-FOR-THIS-ORDER
```

```json
{
  "customer_id": "CUS-XXXXXX",
  "vehicle_id": "VEH-XXXXXX",
  "quote_id": "QUT-XXXXXX",
  "offer_id": "OFF-XXXXXX"
}
```

`Idempotency-Key` إلزامي. عند انقطاع الاتصال أعد نفس الطلب بنفس المفتاح، وسيعيد الخادم نفس Order وInvoice دون تكرارهما. لا تستخدم المفتاح نفسه لطلب مختلف.

الرد يحتوي على:

```json
{
  "order_id": "ORD-XXXXXX",
  "status": "PENDING_PAYMENT",
  "selected_offer": {},
  "invoice": {
    "invoice_id": "INV-XXXXXX",
    "amount": 1530,
    "currency": "SAR",
    "status": "UNPAID",
    "payment_url": "https://api.example.com/mock-pay/ORD-XXXXXX"
  }
}
```

واجهات الاستعلام:

```http
GET /api/v1/orders/{order_id}
GET /api/v1/orders/{order_id}/status
GET /api/v1/invoices/{invoice_id}
```

## 7. محاكاة الدفع

نجاح الدفع:

```http
POST /api/v1/testing/payments/{invoice_id}/success
```

يحوّل Invoice إلى `PAID` وOrder إلى `PAID`.

فشل الدفع:

```http
POST /api/v1/testing/payments/{invoice_id}/fail
```

يحوّل Invoice إلى `FAILED`، ويبقى Order في `PENDING_PAYMENT` للسماح بإعادة المحاولة.

التحقق من الدفع:

```http
GET /api/v1/invoices/{invoice_id}/payment-status
```

لا تعتمد على كلام المستخدم بأنه دفع؛ اعتمد فقط على `payment_status` من هذه الواجهة.

## 8. إصدار الوثيقة

```http
POST /api/v1/policies
```

```json
{"order_id":"ORD-XXXXXX"}
```

لا يسمح الخادم بإصدار الوثيقة إلا بعد نجاح الدفع. يرجع:

```json
{
  "policy_id": "POL-XXXXXX",
  "policy_number": "CON-2026-XXXXXX",
  "order_id": "ORD-XXXXXX",
  "status": "ACTIVE",
  "coverage": {
    "start_date": "2026-09-13",
    "end_date": "2027-09-12",
    "coverage_amount": 85000,
    "deductible": 250
  },
  "document_url": "https://api.example.com/documents/ORD-XXXXXX.pdf"
}
```

إعادة طلب الإصدار لن تنشئ وثيقة ثانية، بل تعيد الوثيقة نفسها.

جلب الوثيقة:

```http
GET /api/v1/policies/{policy_id}
```

## أكواد HTTP المهمة

| Code | المعنى |
|---|---|
| 200 | تم الطلب بنجاح |
| 201 | تم إنشاء المورد |
| 400 | بيانات ناقصة أو Idempotency-Key غير موجود |
| 401 | JWT غير موجود أو غير صالح |
| 404 | المعرّف غير موجود أو لا ينتمي للمورد المطلوب |
| 409 | تعارض حالة، مثل الإصدار قبل الدفع أو انتهاء Quote |

## مثال سريع بـcurl

```bash
BASE_URL='https://api.example.com'

curl -s "$BASE_URL/api/v1/auth/token" \
  -H 'Content-Type: application/json' \
  -d '{"username":"DEMO_USER_FROM_SECRET_MANAGER","password":"DEMO_PASSWORD_FROM_SECRET_MANAGER"}'
```

ضع قيمة `access` في متغير:

```bash
TOKEN='PASTE_ACCESS_TOKEN_HERE'
curl -s "$BASE_URL/api/v1/health"
curl -s "$BASE_URL/api/v1/customers/CUS-XXXXXX" \
  -H "Authorization: Bearer $TOKEN"
```

## ملفات مساعدة

- يمكن تجربة كل endpoint تفاعليًا من Swagger UI.
- يمكن استيراد `Mock-Concord.postman_collection.json` مباشرة في Postman.
- جميع التواريخ ISO-8601 وجميع المبالغ بالريال السعودي في النسخة الحالية.
