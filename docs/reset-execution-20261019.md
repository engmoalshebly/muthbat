# نتيجة إعادة البداية

أذن المستخدم صراحة بمسح الهاتف والمشروع السحابي sgnbtrcbllnffcyzsjei بالكامل.

- مسحت بيانات حزمة com.muthbat.muthbat على هاتف R3CNC05M1LW؛ أعاد Android نتيجة Success.
- قبل المسح السحابي: 5 مستخدمين، 5 أنشطة، 14 قيدًا، ولا ملفات Storage.
- نفذ المسح في معاملة لبيانات public/private مع auth.users والتبعيات، باستثناء جدول العملات. محاولة إعادة عدادات Auth رفضت بصلاحية ملكية sequence وتراجعت؛ نجحت المحاولة دون تعديل العدادات.
- التحقق بعد المسح: users=0، businesses=0، customers=0، entries=0، sessions=0، objects=0؛ بقيت 11 عملة إعداد. بقيت بنية المشروع وإعداداته وأسراره وسجل الترحيلات.
- طبقت CLI الترحيلات 20261019152511 و20261019153708 و20261019160056 بنجاح.
- عاد رفض الإدارة 403 عند التحقق اللاحق ونشر customer-directory وcustomer-contacts وlocal-notebook-import؛ لم ينجح نشر هذه الوظائف في هذه الخطوة، ولا يصح اعتبار المزامنة جاهزة.
- نجح بناء APK Debug بإعدادات config/supabase.cloud.json بعد إصلاح خطأ إشعار المزامنة عند إغلاق قاعدة الجهاز.

يلزم استعادة صلاحية إدارة مستقرة للمشروع، ثم تشغيل tools/deploy-account-workflow.ps1 وفحص tools/verify-account-contract.sql. المسح لا يستبدل نشر الوظائف الناقصة.

## استكمال النشر

بعد إعادة تسجيل الدخول، نجح نشر customer-directory وcustomer-contacts وlocal-notebook-import إلى sgnbtrcbllnffcyzsjei. نجح verify-account-contract.sql على السحابة بعد النشر. تحقق مستقل أكد users=0 وbusinesses=0 وentries=0 وآخر ترحيل 20261019160056. النسخة الجديدة مثبتة على الهاتف؛ تبقى تجربة إنشاء حساب وعميل ودين من الجهاز اختبار القبول الفعلي.
