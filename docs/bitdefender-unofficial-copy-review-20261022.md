# Bitdefender: طلب مراجعة تصنيف نسخة Android

## نتيجة الفحص المحلي

- التنبيه الظاهر في صورة المستخدم: `Unofficial Copy app detected`، من Bitdefender Mobile Security.
- سُحب `base.apk` من حزمة التطبيق المثبتة ضمن المستخدم 0 وقورنت بصمته بملف release المحلي؛ تطابقت البصمتان تمامًا.
- APK SHA-256: `686FC21BEF6067F7246F48DAF83026D71A37BE4733DE9D38B083C8BE959BBC88`.
- الحزمة: `com.muthbat.muthbat`؛ الاسم: مُثبَت؛ versionName: `0.2.0`؛ versionCode: `2`.
- APK ليس debuggable. نجح فحص توقيعه بواسطة Android apksigner.
- شهادة التوقيع: `CN=Muthbat Upload, OU=Mobile, O=Muthbat, C=YE`.
- شهادة التوقيع SHA-256: `1146189e11a5edb7345fd82a3f6d28bd3e2bf5597d0981b36f0ef623fbcd89b3`، وتطابق بصمة المفتاح الموثقة سابقًا في `docs/production-readiness-20261020.md`.
- الجهاز المتصل: Samsung SM-N986U، Android API 31.

هذا يثبت تطابق ملف التطبيق المثبت مع ملف البناء المحلي وصحة توقيعه، ولا يثبت خلو جميع شيفراته واعتمادياته من البرمجيات الخبيثة أو يفسر قواعد تصنيف Bitdefender الداخلية. التصنيف الخاطئ احتمال يحتاج مراجعة مزود الحماية؛ لم يُؤكد سببه. لا دليل في هذا الفحص أن تفعيل hasFragileUserData هو سبب التنبيه.

لم تُعطّل الحماية، ولم يغيّر اسم الحزمة أو توقيعها، ولم يحذف التطبيق أو بياناته. لم يُرفع APK إلى خدمة فحص عامة ولم يُرسل البلاغ إلى جهة خارجية.

## نص جاهز لمراجعة Bitdefender

Subject: Review request: "Unofficial Copy app detected" for our Android application com.muthbat.muthbat

We develop the Android application Muthbat (مُثبَت), package com.muthbat.muthbat. Bitdefender Mobile Security displays "Unofficial Copy app detected" for the attached developer-built release APK.

We have verified that the installed base.apk exactly matches our locally built release artifact, and Android apksigner verifies its signature. The signing certificate matches the key recorded in our previous production build documentation. Please review whether this classification is incorrect and let us know what evidence of application ownership or distribution is required.

Application version: 0.2.0 (versionCode 2)
APK SHA-256: 686FC21BEF6067F7246F48DAF83026D71A37BE4733DE9D38B083C8BE959BBC88
Signing certificate SHA-256: 1146189e11a5edb7345fd82a3f6d28bd3e2bf5597d0981b36f0ef623fbcd89b3
Device: Samsung SM-N986U, Android API 31
Detection: Unofficial Copy app detected
Distribution of this tested build: local developer APK installed through ADB

Attachments to supply with the report: the exact APK with the hash above and the screenshot of the warning. The Bitdefender app version and detection-definition version were not collected.

## الإرسال

استخدم نموذج [Bitdefender لمراجعة التصنيف](https://www.bitdefender.com/consumer/support/answer/29358/) أو الدعم من داخل Bitdefender. إرسال الملف يتطلب إفصاحًا خارجيًا عن التطبيق؛ هذا المستند مسودة محلية فقط.

الملف الحالي: `mobile/build/app/outputs/flutter-apk/app-release.apk`. يجب إعادة حساب بصمته إذا بُني إصدار جديد قبل إرسال البلاغ.
