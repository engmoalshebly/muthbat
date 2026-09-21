# التشغيل الكامل على جهاز التطوير أو السيرفر

هذا التشغيل مخصص للتطوير والاختبار أو لسيرفر مستقل عبر عنوان IP. لا يستخدم
مشروع Supabase Production ولا ينبغي عرضه للعامة بدون HTTPS وحماية جدار ناري.

## التشغيل

من جذر المستودع:

```bash
./scripts/local-up.sh
```

يكتشف السكربت عنوان IPv4 للسيرفر تلقائياً. يمكن تحديده يدوياً عند الحاجة:

```bash
SERVER_IP=217.216.79.195 ./scripts/local-up.sh
```

السكربت يشغّل:

- Supabase المحلي وEdge Functions.
- OpenWA مع PostgreSQL وDashboard وTraefik. التخزين المحلي وRedis غير مطلوبين للتشغيل الأساسي.
- `insurance-backend` في وضع Demo المعزول.

ملفات البيئة المحلية غير متتبعة في Git. عند أول تشغيل ينشئ السكربت ملفات البيئة الناقصة مع قيم محلية عشوائية، ولا يضعها داخل المستودع.

## عناوين الخدمات

| الخدمة | العنوان |
|---|---|
| Supabase API | `http://SERVER_IP:55321` |
| Supabase Studio | `http://SERVER_IP:55323` |
| OpenWA API | `http://SERVER_IP:2785` |
| OpenWA Dashboard | `http://SERVER_IP:2886` |
| Insurance Demo | `http://SERVER_IP:8000` |

للهاتف الحقيقي استخدم عنوان السيرفر عبر الأمر الجاهز:

```bash
./scripts/run-mobile-ip.sh
```

أما Android Emulator على نفس الجهاز فيمكنه استخدام `http://10.0.2.2:55321`.

## ربط WhatsApp المحلي

افتح Dashboard الخاص بـ OpenWA وأنشئ جلسة WhatsApp ثم امسح QR من تطبيق WhatsApp:

```text
http://127.0.0.1:2886
```

لا يمكن إنشاء جلسة WhatsApp أو مسح QR تلقائيًا من السكربت. قبل ربط الجلسة ستبقى وظائف OTP التي تعتمد على التسليم عبر WhatsApp غير متاحة، بينما تبقى بقية وظائف Supabase المحلية قابلة للاختبار.

## تشغيل التطبيق

```bash
./scripts/run-mobile-ip.sh
```

الأمر يمرر عنوان Supabase العام ومفتاح `anon` المحلي تلقائياً، ولا يحفظ المفتاح
في Git.

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

منافذ IP الحالية مخصصة للاختبار: `55321`, `55323`, `2785`, `2886`, و`8000`.
في الإنتاج أغلقها خلف HTTPS وReverse Proxy، وأنشئ مشروع Supabase Production
مستقلاً.
