import 'package:supabase_flutter/supabase_flutter.dart';

/// استثناء موحد لأخطاء طبقة بيانات التاجر.
///
/// الهدف (خطة 06 خطوة 3.9): منع ابتلاع الأخطاء بـ `return false/null`
/// الصامت، وإيصال سبب الفشل الحقيقي برسالة عربية مفهرسة بالكود إلى طبقة
/// العرض. أخطاء منطق الأعمال القادمة من قاعدة البيانات (مثل
/// «Payment exceeds current balance») تُمرر برسالتها كما هي.
///
/// ملاحظة ملكية: النسخة العامة المشتركة `core/errors/api_exception.dart`
/// يملكها وكيل core (خطة 06 خطوة 3.9). هذه نسخة محلية لمجلد بيانات التاجر
/// إلى أن تصل العامة، وعندها تُستبدل هذه المراجع بها.
class MerchantApiException implements Exception {
  /// كود الخطأ (مثل PGRST202 أو 42501 أو network).
  final String code;

  /// رسالة عربية جاهزة للعرض على المستخدم.
  final String message;

  /// الخطأ الأصلي للتشخيص والسجلات.
  final Object? cause;

  const MerchantApiException({
    required this.code,
    required this.message,
    this.cause,
  });

  /// رسائل مفهرسة بالكود وفق خطة 06 خطوة 3.9.
  static const Map<String, String> _codeMessages = {
    'customer_exists': 'هذا الرقم مسجل بالفعل ضمن عملاء المنشأة.',
    'PGRST202': 'عقد غير متطابق مع الخادم. حدّث التطبيق أو أعد المزامنة.',
    '42501': 'ليست لديك صلاحية لتنفيذ هذا الإجراء.',
    '42703': 'بيانات غير متزامنة مع الخادم. أعد المزامنة.',
    '23505': 'سجل مكرر — العملية نُفذت سابقاً.',
    '23503': 'مرجع غير موجود. زامن البيانات أولاً.',
  };

  /// تحويل أي خطأ من Supabase/الشبكة إلى [MerchantApiException] غني.
  factory MerchantApiException.from(Object error) {
    if (error is MerchantApiException) return error;

    if (error is PostgrestException) {
      final code = error.code ?? '';
      final mapped = _codeMessages[code];
      if (mapped != null) {
        return MerchantApiException(code: code, message: mapped, cause: error);
      }
      // أخطاء raise exception في PL/pgSQL تحمل رسالة أعمال واضحة تُعرض كما هي.
      final serverMessage = error.message;
      if (serverMessage.isNotEmpty) {
        return MerchantApiException(
          code: code.isEmpty ? 'server_error' : code,
          message: serverMessage,
          cause: error,
        );
      }
      return MerchantApiException(
        code: 'server_error',
        message: 'خطأ في الخادم. حاول مجدداً.',
        cause: error,
      );
    }

    if (error is FunctionException) {
      // دوال _shared/http.ts ترجع جسم {error, message}.
      final details = error.details;
      String? serverCode;
      String? serverMessage;
      if (details is Map) {
        serverCode = _readErrorText(details['error']);
        serverMessage = _readErrorText(details['message']);
      }
      if (error.status == 401) {
        return MerchantApiException(
          code: 'unauthorized',
          message: 'انتهت الجلسة. سجّل الدخول مجدداً.',
          cause: error,
        );
      }
      return MerchantApiException(
        code: serverCode ?? 'edge_${error.status}',
        message: serverMessage ?? 'فشل تنفيذ العملية في الخادم.',
        cause: error,
      );
    }

    if (isNetworkError(error)) {
      return MerchantApiException(
        code: 'network',
        message: 'تعذر الاتصال بالخادم. تحقق من اتصالك بالإنترنت.',
        cause: error,
      );
    }

    return MerchantApiException(
      code: 'unknown',
      message: 'حدث خطأ غير متوقع.',
      cause: error,
    );
  }

  /// كشف أخطاء الشبكة (انقطاع اتصال) للتمييز بينها وبين أخطاء العقد/الخادم.
  static String? _readErrorText(Object? value) {
    if (value == null) return null;
    if (value is String && value.trim().isNotEmpty) return value;
    if (value is Map) {
      for (final key in const ['message', 'error', 'details']) {
        final nested = _readErrorText(value[key]);
        if (nested != null) return nested;
      }
    }
    final text = value.toString().trim();
    return text.isEmpty ? null : text;
  }

  static bool isNetworkError(Object error) {
    final text = error.toString();
    return text.contains('SocketException') ||
        text.contains('Failed host lookup') ||
        text.contains('Connection refused') ||
        text.contains('Connection timed out') ||
        text.contains('Connection reset') ||
        text.contains('Network is unreachable') ||
        text.contains('ClientException');
  }

  @override
  String toString() => 'MerchantApiException($code): $message';
}
