# دليل التكامل مع Insurance API

## 1. معلومات الخدمة

هذه واجهة تجريبية لتنفيذ رحلة إصدار تأمين مركبة من خدمة خارجية.

```text
Base URL: https://api.example.com
API Version: v1
Content-Type: application/json
Swagger: https://api.example.com/api/docs/
OpenAPI: https://api.example.com/api/schema/
```

> الخدمة Mock مخصصة للتكامل والاختبار، وليست اتصالًا مباشرًا مع Concord الحقيقي.

## 2. بيانات الدخول والمصادقة

```text
Username: DEMO_USER_FROM_SECRET_MANAGER
Password: DEMO_PASSWORD_FROM_SECRET_MANAGER
```

الحصول على Access Token:

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

مثال الرد:

```json
{
  "refresh": "REFRESH_TOKEN",
  "access": "ACCESS_TOKEN"
}
```

يُرسل Access Token مع جميع طلبات الـAPI التالية:

```http
Authorization: Bearer ACCESS_TOKEN
```

تجديد Access Token:

```http
POST /api/v1/auth/token/refresh
Content-Type: application/json
```

```json
{
  "refresh": "REFRESH_TOKEN"
}
```

## 3. صيغة الاستجابة

الاستجابة الناجحة:

```json
{
  "success": true,
  "data": {}
}
```

استجابة الخطأ:

```json
{
  "success": false,
  "error": {
    "status": 400,
    "details": {}
  }
}
```

## 4. تسلسل التكامل المطلوب

يجب استدعاء الواجهات بالترتيب التالي:

```text
Create Customer
    ↓
Create Vehicle
    ↓
Create Quote / Receive Offers
    ↓
Select Offer
    ↓
Create Order + Invoice
    ↓
Verify Payment
    ↓
Issue Policy
    ↓
Get Policy
```

لا تنشئ الخدمة المستهلكة أرقام `offer_id` أو `order_id` أو `policy_id`. يجب استخدام القيم التي ترجع من هذه الـAPI فقط.

---

## 5. إنشاء العميل

```http
POST /api/v1/customers
```

Request:

```json
{
  "national_id": "1234567890",
  "birth_date": "1995-05-18",
  "phone": "967777123456",
  "full_name": "Mohammed Ahmed"
}
```

الحقول:

| Field | Type | Required | الوصف |
|---|---|---:|---|
| national_id | string | نعم | رقم الهوية، ويجب أن يكون فريدًا |
| birth_date | date | نعم | بالصيغة `YYYY-MM-DD` |
| phone | string | نعم | رقم هاتف العميل |
| full_name | string | لا | الاسم الكامل |

Response `201 Created`:

```json
{
  "success": true,
  "data": {
    "customer_id": "CUS-176088",
    "national_id": "1234567890",
    "phone": "967777123456",
    "full_name": "Mohammed Ahmed"
  }
}
```

جلب العميل:

```http
GET /api/v1/customers/{customer_id}
```

---

## 6. إنشاء المركبة

```http
POST /api/v1/vehicles
```

Request:

```json
{
  "customer_id": "CUS-176088",
  "registration_type": "PRIVATE",
  "plate_no": "12345",
  "brand": "Toyota",
  "model": "Prado",
  "year": 2022,
  "vehicle_value": 85000
}
```

| Field | Type | Required | الوصف |
|---|---|---:|---|
| customer_id | string | نعم | معرّف العميل من الخطوة السابقة |
| registration_type | string | نعم | مثال: `PRIVATE` |
| plate_no | string | نعم | رقم اللوحة |
| brand | string | نعم | العلامة التجارية |
| model | string | نعم | الموديل |
| year | integer | نعم | سنة الصنع |
| vehicle_value | decimal | نعم | قيمة المركبة |

Response `201 Created`:

```json
{
  "success": true,
  "data": {
    "vehicle_id": "VEH-890759",
    "customer_id": "CUS-176088",
    "status": "ACTIVE"
  }
}
```

جلب المركبة:

```http
GET /api/v1/vehicles/{vehicle_id}
```

---

## 7. إنشاء Quote واستلام العروض

```http
POST /api/v1/quotes
```

Request:

```json
{
  "customer_id": "CUS-176088",
  "vehicle_id": "VEH-890759"
}
```

Response `201 Created`:

```json
{
  "success": true,
  "data": {
    "quote_id": "QUT-636562",
    "status": "OPEN",
    "expires_at": "2026-09-14T08:00:00Z",
    "offers": [
      {
        "offer_id": "OFF-100001",
        "provider": "Mock Concord",
        "product": "Comprehensive Basic",
        "premium": 1300.50,
        "deductible": 500,
        "coverage_amount": 85000,
        "currency": "SAR"
      },
      {
        "offer_id": "OFF-479563",
        "provider": "Mock Concord",
        "product": "Comprehensive Plus",
        "premium": 1530,
        "deductible": 250,
        "coverage_amount": 85000,
        "currency": "SAR"
      }
    ]
  }
}
```

احتفظ بـ`quote_id` و`offer_id` الذي اختاره العميل. صلاحية Quote هي 24 ساعة.

جلب Quote:

```http
GET /api/v1/quotes/{quote_id}
```

---

## 8. اختيار العرض

```http
POST /api/v1/quotes/{quote_id}/select
```

Request:

```json
{
  "offer_id": "OFF-479563"
}
```

Response:

```json
{
  "success": true,
  "data": {
    "quote_id": "QUT-636562",
    "selected_offer_id": "OFF-479563",
    "status": "SELECTED"
  }
}
```

عندما يختار المستخدم "العرض الثاني"، يجب على الخدمة المستهلكة تحويل الاختيار إلى `offer_id` المقابل وإرساله. لا ترسل الرقم `2`.

---

## 9. إنشاء Order وInvoice

```http
POST /api/v1/orders
Idempotency-Key: 550e8400-e29b-41d4-a716-446655440000
```

Request:

```json
{
  "customer_id": "CUS-176088",
  "vehicle_id": "VEH-890759",
  "quote_id": "QUT-636562",
  "offer_id": "OFF-479563"
}
```

Response `201 Created`:

```json
{
  "success": true,
  "data": {
    "order_id": "ORD-269324",
    "customer_id": "CUS-176088",
    "vehicle_id": "VEH-890759",
    "quote_id": "QUT-636562",
    "status": "PENDING_PAYMENT",
    "selected_offer": {
      "offer_id": "OFF-479563",
      "product": "Comprehensive Plus",
      "premium": 1530,
      "currency": "SAR"
    },
    "invoice": {
      "invoice_id": "INV-347841",
      "order_id": "ORD-269324",
      "amount": 1530,
      "currency": "SAR",
      "status": "UNPAID",
      "payment_url": "https://api.example.com/mock-pay/ORD-269324",
      "paid_at": null
    }
  }
}
```

قواعد `Idempotency-Key`:

- الترويسة إلزامية في `POST /orders`.
- استخدم UUID جديدًا لكل عملية شراء جديدة.
- عند timeout أو انقطاع الاتصال، أعد الطلب نفسه بالمفتاح نفسه.
- إعادة الطلب نفسه بالمفتاح نفسه ترجع Order نفسه دون تكراره.
- استخدام المفتاح نفسه مع payload مختلف يرجع `409 Conflict`.

الاستعلام عن الطلب:

```http
GET /api/v1/orders/{order_id}
GET /api/v1/orders/{order_id}/status
GET /api/v1/invoices/{invoice_id}
```

---

## 10. الدفع في بيئة الاختبار

محاكاة نجاح الدفع:

```http
POST /api/v1/testing/payments/{invoice_id}/success
Authorization: Bearer ACCESS_TOKEN
```

Response:

```json
{
  "success": true,
  "data": {
    "invoice_id": "INV-347841",
    "payment_id": "PAY-700001",
    "status": "PAID",
    "amount": 1530
  }
}
```

محاكاة فشل الدفع:

```http
POST /api/v1/testing/payments/{invoice_id}/fail
Authorization: Bearer ACCESS_TOKEN
```

عند الفشل يبقى Order في `PENDING_PAYMENT` للسماح بإعادة المحاولة.

التحقق من الدفع:

```http
GET /api/v1/invoices/{invoice_id}/payment-status
```

Response بعد الدفع:

```json
{
  "success": true,
  "data": {
    "invoice_id": "INV-347841",
    "payment_status": "PAID",
    "paid_at": "2026-09-13T08:20:00Z",
    "payment_id": "PAY-700001"
  }
}
```

يجب عدم اعتبار الدفع ناجحًا إلا عندما ترجع هذه الواجهة `payment_status: PAID`.

---

## 11. إصدار الوثيقة

```http
POST /api/v1/policies
```

Request:

```json
{
  "order_id": "ORD-269324"
}
```

Response `201 Created`:

```json
{
  "success": true,
  "data": {
    "policy_id": "POL-372742",
    "policy_number": "CON-2026-269324",
    "order_id": "ORD-269324",
    "customer_id": "CUS-176088",
    "vehicle_id": "VEH-890759",
    "status": "ACTIVE",
    "coverage": {
      "start_date": "2026-09-13",
      "end_date": "2027-09-12",
      "coverage_amount": 85000,
      "deductible": 250
    },
    "document_url": "https://api.example.com/documents/ORD-269324.pdf"
  }
}
```

قواعد الإصدار:

- يجب أن تكون Invoice في حالة `PAID`.
- يجب أن يكون Order في حالة `PAID`.
- محاولة الإصدار قبل الدفع ترجع `409 Conflict`.
- إعادة طلب الإصدار بعد نجاحه تعيد الوثيقة نفسها ولا تنشئ وثيقة مكررة.

جلب الوثيقة:

```http
GET /api/v1/policies/{policy_id}
```

---

## 12. حالات Order

```text
PENDING_PAYMENT → PAID → COMPLETED
```

| Status | الوصف |
|---|---|
| PENDING_PAYMENT | تم إنشاء الطلب وينتظر الدفع |
| PAID | تم إثبات الدفع ويمكن إصدار الوثيقة |
| COMPLETED | صدرت الوثيقة واكتملت العملية |
| CANCELLED | الطلب ملغي |
| FAILED | فشلت العملية |

## 13. حالات Invoice

| Status | الوصف |
|---|---|
| UNPAID | لم يتم الدفع |
| FAILED | فشلت محاولة الدفع ويمكن إعادة المحاولة |
| PAID | تم الدفع بنجاح |

## 14. أكواد HTTP

| Status | الاستخدام |
|---:|---|
| 200 | نجاح الطلب أو إعادة مورد موجود |
| 201 | إنشاء مورد جديد بنجاح |
| 400 | حقول غير صحيحة أو `Idempotency-Key` غير موجود |
| 401 | Access Token مفقود أو منتهي أو غير صحيح |
| 404 | المورد غير موجود أو لا يرتبط بالعميل/المركبة المحددة |
| 409 | تعارض حالة العمل، مثل الإصدار قبل الدفع أو انتهاء Quote |
| 500 | خطأ داخلي؛ لا تفترض نجاح العملية وأعد الاستعلام قبل إعادة POST |

## 15. توصيات التكامل

- خزّن جميع المعرّفات التي ترجع من الخدمة كما هي.
- لا تحسب السعر أو رقم الوثيقة داخل خدمتك.
- اضبط مهلة الاتصال على 30 ثانية.
- عند فشل شبكي في إنشاء Order، أعد الطلب بالمفتاح نفسه.
- تحقق من حالة الدفع من API قبل طلب إصدار Policy.
- لا تسجل JWT أو كلمة المرور في logs.
- جميع التواريخ بصيغة ISO-8601، والمبالغ الحالية بعملة `SAR`.

## 16. فحص الاتصال

لا يحتاج Health Check إلى مصادقة:

```http
GET /api/v1/health
```

الرد المتوقع:

```json
{
  "success": true,
  "data": {
    "status": "healthy",
    "service": "mock-concord-insurance"
  }
}
```

## 17. ملف Postman

يمكن استيراد الملف المرفق `Mock-Concord.postman_collection.json`. يحتوي على جميع الطلبات بالترتيب، ومتغيرات للـBase URL وJWT والمعرّفات الناتجة.
