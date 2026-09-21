# إصدار Android Production

## 1. إنشاء مفتاح الرفع

نفّذ الأمر التالي على جهاز إصدار آمن، وليس داخل المستودع:

```bash
keytool -genkeypair -v \
  -keystore muthbat-upload.jks \
  -alias muthbat-upload \
  -keyalg RSA -keysize 4096 -validity 10000
```

احتفظ بملف `muthbat-upload.jks` وكلمات المرور في مدير أسرار مؤسسي. لا ترفع الملف أو `key.properties` إلى Git.

## 2. Play App Signing

1. أنشئ التطبيق في Google Play Console باستخدام المعرّف `com.muthbat.muthbat`.
2. فعّل Play App Signing.
3. اختر **Use an existing app signing key** فقط إذا كانت سياسة مفاتيح المؤسسة تتطلب ذلك؛ وإلا دع Google ينشئ مفتاح توقيع التطبيق.
4. ارفع ملف الـ AAB الناتج من CI كـ **upload key**.
5. سجّل بصمات SHA-1 وSHA-256 لمفتاح الرفع ومفتاح توقيع التطبيق لدى مزوّدي OAuth/Maps/Push عند الحاجة.

## 3. أسرار GitHub Actions

أضف الأسرار التالية إلى بيئة `production` في GitHub، مع تقييدها بفرع `main`:

- `ANDROID_KEYSTORE_BASE64`: ناتج `base64 -w 0 muthbat-upload.jks`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`
- `ANDROID_STORE_PASSWORD`
- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`

تقوم وظيفة `flutter-build` بإنشاء `android/key.properties` مؤقتًا وبناء:

```text
build/app/outputs/bundle/release/app-release.aab
```

لا تستخدم توقيع debug في release؛ يفشل Gradle إذا لم يكن `key.properties` ومفتاح غير debug موجودين.

## 4. فحص الإصدار قبل الرفع

```bash
flutter analyze --no-fatal-infos
flutter test
flutter build appbundle --release \
  --dart-define=SUPABASE_URL="$SUPABASE_URL" \
  --dart-define=SUPABASE_ANON_KEY="$SUPABASE_ANON_KEY" \
  --dart-define=APP_ENV=prod
```

بعد أول رفع، فعّل في Play Console اختبارات Internal testing ثم راجع سياسة الخصوصية، Data safety، الأذونات، ونتيجة pre-launch report قبل التوسّع إلى Production.
