# التشغيل المحلي الكامل

هذا التشغيل مخصص للتطوير والاختبار المحلي فقط، ولا يستخدم مشروع Supabase Production.

## التشغيل

من جذر المستودع:

```bash
./scripts/local-up.sh
```

السكربت يشغّل:

- Supabase المحلي وEdge Functions.
- OpenWA مع PostgreSQL وDashboard وTraefik. التخزين المحلي وRedis غير مطلوبين للتشغيل الأساسي.
- `insurance-backend` في وضع Demo المعزول.

ملفات البيئة المحلية غير متتبعة في Git. عند أول تشغيل ينشئ السكربت ملفات البيئة الناقصة مع قيم محلية عشوائية، ولا يضعها داخل المستودع.

## عناوين الخدمات

| الخدمة | العنوان |
|---|---|
| Supabase API | `http://127.0.0.1:55321` |
| Supabase Studio | `http://127.0.0.1:55323` |
| OpenWA API | `http://127.0.0.1:2785` |
| OpenWA Dashboard | `http://127.0.0.1:2886` |
| Insurance Demo | `http://127.0.0.1:8000` |

لـ Android Emulator يستخدم التطبيق تلقائيًا `http://10.0.2.2:55321` للوصول إلى Supabase على جهاز التطوير.

## ربط WhatsApp المحلي

افتح Dashboard الخاص بـ OpenWA وأنشئ جلسة WhatsApp ثم امسح QR من تطبيق WhatsApp:

```text
http://127.0.0.1:2886
```

لا يمكن إنشاء جلسة WhatsApp أو مسح QR تلقائيًا من السكربت. قبل ربط الجلسة ستبقى وظائف OTP التي تعتمد على التسليم عبر WhatsApp غير متاحة، بينما تبقى بقية وظائف Supabase المحلية قابلة للاختبار.

## تشغيل التطبيق

```bash
cd mobile
flutter run --dart-define=APP_ENV=dev
```

## الإيقاف

```bash
./scripts/local-down.sh
```

الإيقاف لا يحذف volumes أو بيانات OpenWA المحلية. لحذف بيانات التطوير يدويًا، راجع أسماء volumes عبر Docker قبل أي حذف.

## فحص سريع

```bash
curl http://127.0.0.1:2785/api/health
curl http://127.0.0.1:8000/api/v1/health
```

خدمة التأمين Demo فقط، ولا تستخدمها كخدمة تأمين حقيقية أو كواجهة عامة.
