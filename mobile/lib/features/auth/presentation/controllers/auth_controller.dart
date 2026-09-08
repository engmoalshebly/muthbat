import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// hide AuthState: اسم يتعارض مع AuthState الخاصة بهذا المتحكم.
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

import '../../../../core/database/app_database.dart';
import '../../../../core/config/env.dart';
import '../../../../core/sync/sync_engine.dart';
import '../validators/auth_validators.dart';

/// متحكم المصادقة — «مُثبَت | MUTHBAT»
///
/// مصدر الحقيقة الوحيد للجلسة هو Supabase Auth (PKCE + refresh token):
/// `Supabase.auth.currentSession` + مستمع `onAuthStateChange`.
/// لا تخزين لأي هوية في SharedPreferences، ولا OTP في جهاز العميل،
/// ولا هويات محلية مفبركة من أي نوع.
///
/// ┌──────────────────────────────────────────────────────────────────┐
/// │ مسار OTP: Supabase Phone Auth الأصلي (signInWithOtp / verifyOTP)  │
/// │ مع مزود Twilio Verify (قناة WhatsApp بقالب معتمد من Meta).        │
/// │                                                                    │
/// │ الأسرار المطلوبة (خادمية فقط — تُضبط عبر `supabase secrets set`   │
/// │ لكل مشروع staging/prod، وفي config.toml تحت [auth.sms.twilio_verify]):
/// │   TWILIO_ACCOUNT_SID / TWILIO_AUTH_TOKEN / TWILIO_VERIFY_SERVICE_SID│
/// │ ويُفعَّل [auth.sms] enable_signup = true و enable_confirmations.   │
/// │ لا يوجد أي سر أو رمز OTP داخل هذا التطبيق.                         │
/// └──────────────────────────────────────────────────────────────────┘

enum AuthStatus {
  initial,
  loading,
  unauthenticated,
  otpSent,
  authenticated,
  error,
}

/// سياق شاشة إدخال رمز التحقق: تسجيل جديد أم استرداد حساب.
enum AuthPendingAction { signup, recovery }

/// نتيجة طلب تسجيل الخروج — تسمح للواجهة بعرض حوار تحذير الطابور.
class SignOutResult {
  /// true إذا أُغلقت الجلسة فعلاً.
  final bool signedOut;

  /// عدد العمليات المعلقة في طابور المزامنة عند إجهاض الخروج (0 عند النجاح).
  final int pendingCount;

  const SignOutResult({required this.signedOut, this.pendingCount = 0});
}

class AuthState {
  final AuthStatus status;
  final String? userId;
  final String? phoneNumber;
  final String? displayName;
  final String userType; // 'merchant' or 'customer'
  /// التاجر لا يدخل لوحة التحكم قبل إنشاء منشأته الأساسية.
  final bool requiresBusinessSetup;
  final String? errorMessage;
  final String? challengeId; // معرّف تحدي OTP من الخادم
  final String? pendingPassword; // كلمة السر قيد التسجيل
  /// رمز استرداد يبقى في الذاكرة فقط حتى إدخال كلمة السر الجديدة.
  final String? recoveryOtpCode;

  /// سياق شاشة OTP الحالية (signup/recovery) — null خارج تدفق OTP.
  final AuthPendingAction? pendingAction;

  const AuthState({
    this.status = AuthStatus.initial,
    this.userId,
    this.phoneNumber,
    this.displayName,
    this.userType = 'merchant',
    this.requiresBusinessSetup = false,
    this.errorMessage,
    this.challengeId,
    this.pendingPassword,
    this.recoveryOtpCode,
    this.pendingAction,
  });

  AuthState copyWith({
    AuthStatus? status,
    String? userId,
    String? phoneNumber,
    String? displayName,
    String? userType,
    bool? requiresBusinessSetup,
    String? errorMessage,
    String? challengeId,
    String? pendingPassword,
    String? recoveryOtpCode,
    AuthPendingAction? pendingAction,
    bool clearPendingAction = false,
  }) {
    return AuthState(
      status: status ?? this.status,
      userId: userId ?? this.userId,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      displayName: displayName ?? this.displayName,
      userType: userType ?? this.userType,
      requiresBusinessSetup:
          requiresBusinessSetup ?? this.requiresBusinessSetup,
      errorMessage: errorMessage,
      challengeId: challengeId ?? this.challengeId,
      pendingPassword: pendingPassword ?? this.pendingPassword,
      recoveryOtpCode: recoveryOtpCode ?? this.recoveryOtpCode,
      pendingAction: clearPendingAction
          ? null
          : (pendingAction ?? this.pendingAction),
    );
  }
}

class AuthController extends StateNotifier<AuthState> {
  AuthController() : super(const AuthState()) {
    _readyFuture = _initFromSupabaseSession();
  }

  GoTrueClient get _auth => Supabase.instance.client.auth;
  late final Future<void> _readyFuture;

  Future<void> get ready => _readyFuture;

  // نوع الحدث الخام هو AuthState الخاصة بـ supabase_flutter (مخفية عن الاستيراد).
  StreamSubscription<dynamic>? _authEventSubscription;
  bool _explicitSignOut = false;

  Future<bool> _restoreLocalOwner() async {
    final business = await AppDatabase.instance.restoreRememberedOwner();
    if (business == null) {
      final profile = await AppDatabase.instance.restoreRememberedCustomer();
      if (profile == null) return false;
      state = AuthState(
        status: AuthStatus.authenticated,
        userId: AppDatabase.instance.accountId,
        userType: 'customer',
        displayName: profile['display_name'] as String?,
        phoneNumber: profile['phone'] as String?,
      );
      return true;
    }
    state = AuthState(
      status: AuthStatus.authenticated,
      userId: AppDatabase.instance.accountId,
      userType: 'merchant',
      displayName: business['name'] as String?,
    );
    return true;
  }

  // ---------------------------------------------------------------------------
  // استعادة الجلسة (§3.4) — من Supabase SDK فقط، لا SharedPreferences
  // ---------------------------------------------------------------------------

  Future<void> _initFromSupabaseSession() async {
    try {
      final localOwner = await _restoreLocalOwner();
      // اشتراك دائم بأحداث المصادقة: خروج/تحديث توكن يعكسان على الحالة فوراً.
      _authEventSubscription = _auth.onAuthStateChange.listen((data) async {
        final event = data.event;
        if (event == AuthChangeEvent.signedOut) {
          if (_explicitSignOut || !await _restoreLocalOwner()) {
            state = state.copyWith(status: AuthStatus.unauthenticated);
          }
        } else if (event == AuthChangeEvent.tokenRefreshed ||
            event == AuthChangeEvent.signedIn) {
          final session = data.session;
          if (session != null &&
              (state.status != AuthStatus.authenticated ||
                  session.user.id != state.userId) &&
              state.status != AuthStatus.loading) {
            state = state.copyWith(status: AuthStatus.loading);
            await _loadProfile();
          }
        }
      });

      var session = _auth.currentSession;
      if (localOwner) {
        // Open immediately from disk. The SDK refreshes online independently.
        // A different account must complete its explicit sign-in before use.
        if (session == null || session.user.id == state.userId) {
          if (session != null && !session.isExpired) {
            SyncEngine.instance.triggerSync();
          }
          return;
        }
      }
      final persistedSession = session;
      if (session?.isExpired == true) {
        try {
          session = (await _auth.refreshSession().timeout(
            const Duration(seconds: 8),
          )).session;
        } catch (e) {
          debugPrint('[AuthController] persisted session refresh failed: $e');
          // Only an established owner can keep using their own cached notebook
          // after a transient network failure. Revoked credentials and employee
          // sessions do not acquire an offline owner identity.
          if (persistedSession != null &&
              (e is SocketException || e is TimeoutException)) {
            await AppDatabase.instance.bindAccount(persistedSession.user.id);
            final business = await AppDatabase.instance.getBusinessByOwnerId(
              persistedSession.user.id,
            );
            if (business != null) {
              state = AuthState(
                status: AuthStatus.authenticated,
                userId: persistedSession.user.id,
                phoneNumber: persistedSession.user.phone,
                userType: 'merchant',
                displayName: business['name'] as String?,
                errorMessage:
                    'أعد تسجيل الدخول لاستكمال المزامنة. العمل المحلي متاح.',
              );
              return;
            }
          }
          session = null;
        }
      }

      if (session != null && !session.isExpired) {
        state = state.copyWith(status: AuthStatus.loading);
        await _loadProfile();
        if (state.status == AuthStatus.loading) {
          // تعذر تحميل الملف الشخصي رغم جلسة حية — نبقي الدخول مع بيانات الحد الأدنى.
          state = state.copyWith(
            status: AuthStatus.authenticated,
            userId: session.user.id,
            phoneNumber: session.user.phone,
          );
        }
        SyncEngine.instance.triggerSync();
      } else {
        state = state.copyWith(status: AuthStatus.unauthenticated);
      }
    } catch (e) {
      debugPrint('[AuthController] Supabase session initialization failed: $e');
      if (state.status != AuthStatus.authenticated) {
        state = state.copyWith(status: AuthStatus.unauthenticated);
      }
    }
  }

  @override
  void dispose() {
    _authEventSubscription?.cancel();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // التسجيل عبر OpenWA OTP: إرسال الرمز من الخادم ثم التحقق
  // ---------------------------------------------------------------------------

  /// بدء التسجيل: يطلب رمز التحقق عبر واتساب (OpenWA) ويحفظ معرف التحدي.
  Future<bool> registerStart({
    required String name,
    required String phone,
    required String password,
    required String userType,
  }) async {
    state = state.copyWith(status: AuthStatus.loading, errorMessage: null);

    try {
      final validationError =
          AuthValidators.nameError(name) ??
          AuthValidators.passwordError(password);
      if (validationError != null) {
        state = state.copyWith(
          status: AuthStatus.error,
          errorMessage: validationError,
        );
        return false;
      }
      final normalizedPhone = AuthValidators.normalizeE164(phone);
      if (EnvConfig.isStaging) {
        return _registerDirectlyForStaging(
          name: name,
          phone: normalizedPhone,
          password: password,
          userType: userType,
        );
      }
      final res = await Supabase.instance.client.functions
          .invoke(
            'send-whatsapp-otp',
            body: {'phone': normalizedPhone, 'appName': 'Muthbat'},
          )
          .timeout(const Duration(seconds: 25));

      final data = res.data is Map
          ? Map<String, dynamic>.from(res.data as Map)
          : null;
      if (data == null ||
          data['success'] != true ||
          data['challengeId'] == null) {
        final err =
            (data != null && data['error'] is Map
                ? data['error']['message']
                : null) ??
            'تعذر إرسال رمز التحقق عبر واتساب.';
        state = state.copyWith(
          status: AuthStatus.error,
          errorMessage: err.toString(),
        );
        return false;
      }

      final challengeId = data['challengeId'].toString();
      state = state.copyWith(
        status: AuthStatus.otpSent,
        phoneNumber: normalizedPhone,
        displayName: name.trim(),
        userType: userType,
        challengeId: challengeId,
        pendingPassword: password,
        pendingAction: AuthPendingAction.signup,
      );
      return true;
    } catch (e) {
      debugPrint('[AuthController] registerStart error: $e');
      state = state.copyWith(
        status: AuthStatus.error,
        errorMessage: _mapAuthError(
          e,
          fallback: 'تعذر إرسال رمز التحقق عبر واتساب. تحقق من الشبكة.',
        ),
      );
      return false;
    }
  }

  /// Closed-beta fallback while the WhatsApp gateway is intentionally off.
  /// The Edge Function is fail-closed unless staging enables it explicitly.
  Future<bool> _registerDirectlyForStaging({
    required String name,
    required String phone,
    required String password,
    required String userType,
  }) async {
    final res = await Supabase.instance.client.functions
        .invoke(
          'staging-direct-signup',
          body: {
            'phone': phone,
            'password': password,
            'displayName': name.trim(),
            'userType': userType,
          },
        )
        .timeout(const Duration(seconds: 25));
    final data = res.data is Map
        ? Map<String, dynamic>.from(res.data as Map)
        : null;
    if (data?['success'] != true) {
      final error = data?['error'];
      final message = error is Map ? error['message'] : null;
      throw AuthException(
        (message ?? 'تعذر إنشاء الحساب التجريبي.').toString(),
      );
    }

    await _signInWithPhoneOrEmail(phone, password);
    await _bootstrapUserContact();
    await _loadProfile();
    state = state.copyWith(
      status: AuthStatus.authenticated,
      clearPendingAction: true,
    );
    SyncEngine.instance.triggerSync();
    return true;
  }

  /// التحقق من رمز تسجيل جديد وتفعيل جلسة Supabase الحقيقية.
  Future<bool> verifySignupOtp(String enteredCode) async {
    final phone = state.phoneNumber;
    final challengeId = state.challengeId;
    if (phone == null || challengeId == null) {
      state = state.copyWith(
        status: AuthStatus.error,
        errorMessage: 'انتهت جلسة التحقق. يرجى إعادة التسجيل.',
      );
      return false;
    }

    final normalizedCode = AuthValidators.normalizeOtp(enteredCode.trim());
    final codeError = AuthValidators.otpError(normalizedCode);
    if (codeError != null) {
      state = state.copyWith(
        status: AuthStatus.otpSent,
        errorMessage: codeError,
      );
      return false;
    }

    state = state.copyWith(status: AuthStatus.loading, errorMessage: null);

    try {
      final res = await Supabase.instance.client.functions.invoke(
        'verify-whatsapp-otp',
        body: {
          'challengeId': challengeId,
          'code': normalizedCode,
          'phone': phone,
          'password': state.pendingPassword,
          'displayName': state.displayName,
          'userType': state.userType,
          'action': 'signup',
        },
      );

      final data = res.data is Map ? res.data as Map<String, dynamic> : null;
      if (data == null || data['success'] != true) {
        final err =
            (data != null && data['error'] is Map
                ? data['error']['message']
                : null) ??
            'رمز التحقق غير صحيح أو منتهي الصلاحية.';
        state = state.copyWith(
          status: AuthStatus.otpSent,
          errorMessage: err.toString(),
        );
        return false;
      }

      // تسجيل الدخول بكلمة السر لإنشاء وتفعيل جلسة GoTrue الرسمية.
      if (state.pendingPassword != null && state.pendingPassword!.isNotEmpty) {
        try {
          await _signInWithPhoneOrEmail(phone, state.pendingPassword!);
        } catch (signInErr) {
          debugPrint('[AuthController] GoTrue signIn error: $signInErr');
          state = state.copyWith(
            status: AuthStatus.error,
            errorMessage:
                'تم إنشاء الحساب، لكن تعذر فتح الجلسة. سجّل الدخول مرة أخرى.',
          );
          return false;
        }
      }

      await _bootstrapUserContact();
      await _loadProfile();

      state = state.copyWith(
        status: AuthStatus.authenticated,
        pendingPassword: '',
        clearPendingAction: true,
      );

      SyncEngine.instance.triggerSync();
      return true;
    } catch (e) {
      debugPrint('[AuthController] verifySignupOtp error: $e');
      state = state.copyWith(
        status: AuthStatus.otpSent,
        errorMessage: _mapAuthError(
          e,
          fallback: 'رمز التحقق غير صحيح أو منتهي الصلاحية.',
        ),
      );
      return false;
    }
  }

  /// تسجيل الدخول بالهوية الرسمية الوحيدة للتطبيق: رقم الهاتف بصيغة E.164.
  Future<AuthResponse> _signInWithPhoneOrEmail(
    String phone,
    String password,
  ) async {
    final e164 = AuthValidators.normalizeE164(phone);
    await SyncEngine.instance.pauseAndDrain();
    try {
      final response = await _auth
          .signInWithPassword(phone: e164, password: password)
          .timeout(const Duration(seconds: 25));
      if (response.user != null) {
        await AppDatabase.instance.bindAccount(response.user!.id);
      }
      return response;
    } finally {
      SyncEngine.instance.resume();
    }
  }

  // ---------------------------------------------------------------------------
  // الدخول (§3.2): كلمة السر عبر Supabase فقط — بلا أي fallback محلي
  // ---------------------------------------------------------------------------

  Future<bool> loginWithPassword({
    required String phone,
    required String password,
  }) async {
    state = state.copyWith(status: AuthStatus.loading, errorMessage: null);

    try {
      final passwordError = AuthValidators.passwordError(password);
      if (passwordError != null) {
        state = state.copyWith(
          status: AuthStatus.error,
          errorMessage: passwordError,
        );
        return false;
      }
      await _signInWithPhoneOrEmail(phone, password);

      // idempotent: يسجّل الهاتف المشفر لأي حساب قائم لم يُسجَّل بعد.
      await _bootstrapUserContact();
      await _loadProfile();

      state = state.copyWith(
        status: AuthStatus.authenticated,
        clearPendingAction: true,
      );

      SyncEngine.instance.triggerSync();
      return true;
    } catch (e) {
      debugPrint('[AuthController] loginWithPassword error: $e');
      state = state.copyWith(
        status: AuthStatus.error,
        errorMessage: _mapAuthError(
          e,
          fallback:
              'رقم الهاتف أو كلمة السر غير صحيحة. يرجى المحاولة مرة أخرى.',
        ),
      );
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // استرداد الحساب: OTP عبر OpenWA → جلسة → كلمة سر جديدة
  // ---------------------------------------------------------------------------

  /// إرسال رمز استرداد عبر واتساب (OpenWA).
  Future<bool> sendRecoveryOtp({required String phone}) async {
    state = state.copyWith(status: AuthStatus.loading, errorMessage: null);

    try {
      final normalizedPhone = AuthValidators.normalizeE164(phone);
      final res = await Supabase.instance.client.functions.invoke(
        'send-whatsapp-otp',
        body: {'phone': normalizedPhone, 'appName': 'Muthbat'},
      );

      final data = res.data is Map ? res.data as Map<String, dynamic> : null;
      if (data == null ||
          data['success'] != true ||
          data['challengeId'] == null) {
        final err =
            (data != null && data['error'] is Map
                ? data['error']['message']
                : null) ??
            'تعذر إرسال رمز التحقق عبر واتساب.';
        state = state.copyWith(
          status: AuthStatus.error,
          errorMessage: err.toString(),
        );
        return false;
      }

      final challengeId = data['challengeId'].toString();
      state = state.copyWith(
        status: AuthStatus.otpSent,
        phoneNumber: normalizedPhone,
        challengeId: challengeId,
        pendingAction: AuthPendingAction.recovery,
      );
      return true;
    } catch (e) {
      debugPrint('[AuthController] sendRecoveryOtp error: $e');
      state = state.copyWith(
        status: AuthStatus.error,
        errorMessage: _mapAuthError(
          e,
          fallback: 'تعذر إرسال رمز التحقق عبر واتساب.',
        ),
      );
      return false;
    }
  }

  /// التحقق من رمز الاسترداد عبر OpenWA.
  Future<bool> verifyRecoveryOtp(String enteredCode) async {
    final phone = state.phoneNumber;
    final challengeId = state.challengeId;
    if (phone == null || challengeId == null) {
      state = state.copyWith(
        status: AuthStatus.error,
        errorMessage: 'انتهت جلسة التحقق. يرجى إعادة طلب الرمز.',
      );
      return false;
    }

    // نحتفظ بالرمز في الذاكرة فقط. استهلاكه يتم مع كلمة السر الجديدة في طلب
    // واحد ذري، لذلك لا يمكن الوصول إلى شاشة إعادة التعيين بجلسة وهمية.
    final normalizedCode = AuthValidators.normalizeOtp(enteredCode.trim());
    final codeError = AuthValidators.otpError(normalizedCode);
    if (codeError != null) {
      state = state.copyWith(
        status: AuthStatus.otpSent,
        errorMessage: 'رمز التحقق يجب أن يتكون من 6 أرقام.',
      );
      return false;
    }
    state = state.copyWith(
      status: AuthStatus.initial,
      recoveryOtpCode: normalizedCode,
    );
    return true;
  }

  /// تعيين كلمة السر الجديدة بعد نجاح تحقق الاسترداد.
  Future<bool> completePasswordReset({required String newPassword}) async {
    state = state.copyWith(status: AuthStatus.loading, errorMessage: null);

    try {
      final passwordError = AuthValidators.passwordError(newPassword);
      if (passwordError != null) {
        state = state.copyWith(
          status: AuthStatus.error,
          errorMessage: passwordError,
        );
        return false;
      }
      final phone = state.phoneNumber;
      final challengeId = state.challengeId;
      final code = state.recoveryOtpCode;
      if (phone == null || challengeId == null || code == null) {
        throw const AuthException('انتهت صلاحية التحقق. يرجى طلب رمز جديد.');
      }
      final res = await Supabase.instance.client.functions.invoke(
        'verify-whatsapp-otp',
        body: {
          'challengeId': challengeId,
          'code': code,
          'phone': phone,
          'password': newPassword,
          'action': 'recovery',
        },
      );
      final data = res.data is Map ? res.data as Map<String, dynamic> : null;
      if (data == null || data['success'] != true) {
        throw AuthException(
          (data?['error']?['message'] ?? 'تعذر تعيين كلمة السر الجديدة.')
              .toString(),
        );
      }
      await _signInWithPhoneOrEmail(phone, newPassword);

      await _bootstrapUserContact();
      await _loadProfile();

      state = state.copyWith(
        status: AuthStatus.authenticated,
        recoveryOtpCode: '',
        clearPendingAction: true,
      );

      SyncEngine.instance.triggerSync();
      return true;
    } catch (e) {
      debugPrint('[AuthController] completePasswordReset error: $e');
      state = state.copyWith(
        status: AuthStatus.error,
        errorMessage: _mapAuthError(
          e,
          fallback: 'تعذر تعيين كلمة السر الجديدة. يرجى المحاولة مرة أخرى.',
        ),
      );
      return false;
    }
  }

  /// إعادة إرسال الرمز بحسب سياق الشاشة الحالي عبر OpenWA.
  Future<bool> resendOtp() async {
    final phone = state.phoneNumber;
    if (phone == null) return false;

    state = state.copyWith(status: AuthStatus.loading, errorMessage: null);

    try {
      final normalizedPhone = AuthValidators.normalizeE164(phone);
      final res = await Supabase.instance.client.functions.invoke(
        'send-whatsapp-otp',
        body: {'phone': normalizedPhone, 'appName': 'Muthbat'},
      );

      final data = res.data is Map ? res.data as Map<String, dynamic> : null;
      if (data != null &&
          data['success'] == true &&
          data['challengeId'] != null) {
        final challengeId = data['challengeId'].toString();
        state = state.copyWith(
          status: AuthStatus.otpSent,
          phoneNumber: normalizedPhone,
          challengeId: challengeId,
          recoveryOtpCode: '',
        );
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('[AuthController] resendOtp error: $e');
      state = state.copyWith(
        status: AuthStatus.otpSent,
        errorMessage: _mapAuthError(
          e,
          fallback: 'تعذر إعادة إرسال الرمز الآن. يرجى المحاولة لاحقاً.',
        ),
      );
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // الخروج (§3.5): حارس طابور المزامنة — لا فقدان صامت للبيانات
  // ---------------------------------------------------------------------------

  /// يفحص طابور المزامنة قبل الخروج.
  ///
  /// - طابور فارغ → خروج مباشر ومسح قاعدة البيانات المحلية (لا تسريب بين الحسابات).
  /// - عمليات معلقة → محاولة مزامنة أولاً؛ إن بقيت عمليات يُجهض الخروج ويعيد
  ///   [SignOutResult] بعددها لتعرض الواجهة حوار التحذير
  ///   [مزامنة الآن] / [خروج مع فقدانها]، وعند اختيار الفقدان تُعيد الاستدعاء
  ///   مع discardPendingData: true.
  Future<SignOutResult> signOut({bool discardPendingData = false}) async {
    try {
      _explicitSignOut = true;
      await SyncEngine.instance.pauseAndDrain();
      await AppDatabase.instance.forgetRememberedOwner();
      await _auth.signOut(scope: SignOutScope.local);
      await AppDatabase.instance.lockAccount();

      state = const AuthState(status: AuthStatus.unauthenticated);
      return const SignOutResult(signedOut: true);
    } catch (e) {
      debugPrint('[AuthController] signOut error: $e');
      // فشل الخروج أو المسح لا يمنح إذناً بحذف العمليات غير المزامنة.
      // لا نعلن نجاح الخروج إذا لم تكتمل خطواته.
      state = state.copyWith(
        errorMessage:
            'تعذر إكمال تسجيل الخروج. احتُفظ بالبيانات المحلية؛ حاول مجدداً.',
      );
      return const SignOutResult(signedOut: false);
    } finally {
      _explicitSignOut = false;
      SyncEngine.instance.resume();
    }
  }

  void reset() {
    state = const AuthState(status: AuthStatus.unauthenticated);
  }

  /// Only cached ownership determines local workspace availability; this is
  /// not a server role grant or a change to the customer's personal identity.
  Future<void> refreshLocalBusinessAccess() async {
    final owner = state.userId;
    if (owner == null || AppDatabase.instance.accountId != owner) return;
    final business = await AppDatabase.instance.getBusinessByOwnerId(owner);
    if (!mounted || state.userId != owner || business == null) return;
    state = state.copyWith(userType: 'merchant', requiresBusinessSetup: false);
  }

  // ---------------------------------------------------------------------------
  // أدوات داخلية
  // ---------------------------------------------------------------------------

  /// قراءة الملف الشخصي من public.profiles عبر RLS، مع تخزين واسترجاع محلي (SQLite) للعمل بدون إنترنت.
  Future<void> _loadProfile() async {
    final user = _auth.currentUser;
    if (user == null) return;
    await AppDatabase.instance.forgetRememberedOwner();
    if (AppDatabase.instance.accountId != user.id) {
      await SyncEngine.instance.pauseAndDrain();
      try {
        await AppDatabase.instance.bindAccount(user.id);
      } finally {
        SyncEngine.instance.resume();
      }
    }

    String? displayName = user.userMetadata?['display_name'] as String?;
    String userType =
        (user.userMetadata?['user_type'] as String?) ?? state.userType;
    final now = DateTime.now().toIso8601String();

    try {
      final row = await Supabase.instance.client
          .from('profiles')
          .select('display_name, user_type')
          .eq('id', user.id)
          .maybeSingle()
          .timeout(const Duration(seconds: 8));
      if (row != null) {
        displayName = row['display_name'] as String?;
        userType = (row['user_type'] as String?) ?? userType;

        // حفظ في الكاش المحلي (SQLite) لتمكين فتح التطبيق أوفلاين
        await AppDatabase.instance.saveProfile({
          'id': user.id,
          'display_name': displayName ?? 'مستخدم',
          'user_type': userType,
          'phone': user.phone ?? state.phoneNumber,
          'updated_at': now,
        });
        await AppDatabase.instance.rememberCustomer();
      }
    } catch (e) {
      debugPrint(
        '[AuthController] profiles remote fetch error (offline fallback): $e',
      );
      // محاولة القراءة من الكاش المحلي (SQLite) عند انقطاع الإنترنت
      try {
        final cached = await AppDatabase.instance.getProfile(user.id);
        if (cached != null) {
          displayName = cached['display_name'] as String?;
          userType = (cached['user_type'] as String?) ?? userType;
        }
      } catch (_) {}
      displayName ??= (user.userMetadata?['display_name'] as String?);
      userType = (user.userMetadata?['user_type'] as String?) ?? userType;
    }

    // Business ownership, checked under the user's RLS session, enables the
    // merchant workspace even if the account originally registered as customer.
    try {
      final owned = await Supabase.instance.client
          .from('businesses')
          .select('id')
          .eq('owner_user_id', user.id)
          .eq('status', 'active')
          .limit(1)
          .maybeSingle()
          .timeout(const Duration(seconds: 8));
      if (owned != null) userType = 'merchant';
    } catch (_) {
      if (await AppDatabase.instance.getBusinessByOwnerId(user.id) != null) {
        userType = 'merchant';
      }
    }

    await AppDatabase.instance.rememberCustomer();
    await AppDatabase.instance.rememberOwner();
    final requiresBusinessSetup = await _resolveBusinessSetupRequirement(
      user.id,
      userType,
    );

    state = state.copyWith(
      status: AuthStatus.authenticated,
      userId: user.id,
      phoneNumber: user.phone ?? state.phoneNumber,
      displayName: displayName ?? state.displayName,
      userType: userType,
      requiresBusinessSetup: requiresBusinessSetup,
    );
  }

  /// يفحص الخادم عند كل استعادة جلسة/دخول، مع fallback للكاش عند انقطاع الشبكة.
  Future<bool> _resolveBusinessSetupRequirement(
    String userId,
    String userType,
  ) async {
    if (userType != 'merchant') return false;
    try {
      final business = await Supabase.instance.client
          .from('businesses')
          .select('id')
          .eq('owner_user_id', userId)
          .eq('status', 'active')
          .limit(1)
          .maybeSingle()
          .timeout(const Duration(seconds: 8));
      return business == null;
    } catch (e) {
      debugPrint('[AuthController] business setup check offline: $e');
      final cached = await AppDatabase.instance.getBusinessByOwnerId(userId);
      return cached == null;
    }
  }

  /// استدعاء bootstrap-user-contact مرة واحدة بعد أول تحقق/دخول ناجح (§2).
  /// idempotent من جهة الخادم — الفشل هنا لا يمنع الدخول ويُعاد عند الدخول التالي.
  Future<void> _bootstrapUserContact() async {
    try {
      await Supabase.instance.client.functions
          .invoke('bootstrap-user-contact')
          .timeout(const Duration(seconds: 8));
    } catch (e) {
      debugPrint('[AuthController] bootstrap-user-contact deferred: $e');
    }
  }

  /// خريطة أخطاء المصادقة إلى رسائل عربية مميزة (بيانات خاطئة/شبكة/حظر).
  String _mapAuthError(Object e, {required String fallback}) {
    if (e is SocketException || e is HttpException) {
      return 'لا يوجد اتصال بالإنترنت. تحقق من الشبكة وحاول مجدداً.';
    }
    if (e is AuthException) {
      final msg = e.message.toLowerCase();
      if (msg.contains('invalid login credentials')) {
        return 'رقم الهاتف أو كلمة السر غير صحيحة.';
      }
      if (msg.contains('already registered') ||
          msg.contains('already been registered')) {
        return 'هذا الرقم مسجل مسبقاً. سجّل دخولك أو استعد حسابك.';
      }
      if (msg.contains('expired') ||
          (msg.contains('invalid') && msg.contains('token')) ||
          msg.contains('otp')) {
        return 'رمز التحقق غير صحيح أو منتهي الصلاحية.';
      }
      if (e.statusCode == '429' ||
          msg.contains('too many') ||
          msg.contains('rate limit')) {
        return 'محاولات كثيرة جداً. يرجى الانتظار قليلاً ثم المحاولة مجدداً.';
      }
      if (msg.contains('network') || msg.contains('connection')) {
        return 'لا يوجد اتصال بالإنترنت. تحقق من الشبكة وحاول مجدداً.';
      }
    }
    if (e is FunctionException) {
      final details = e.details;
      final detailsText = details is Map
          ? '${details['error'] ?? details['message'] ?? details}'
          : '$details';
      final message = '${e.reasonPhrase ?? ''} $detailsText'.toLowerCase();
      if (e.status == 409 || message.contains('account_exists')) {
        return 'هذا الرقم مسجل مسبقًا. اختر «تسجيل الدخول» بدل إنشاء حساب.';
      }
      if (e.status == 403 || message.contains('direct_auth_disabled')) {
        return 'التسجيل المباشر غير مفعّل لهذه البيئة.';
      }
      if (e.status == 422 && message.contains('invalid_phone')) {
        return 'رقم الهاتف غير صالح. أدخله مع رمز الدولة.';
      }
      if (e.status == 429 || message.contains('rate_limited')) {
        return 'محاولات كثيرة جدًا. انتظر قليلًا ثم حاول مرة أخرى.';
      }
      if (e.status == 502 || message.contains('otp_delivery_failed')) {
        return 'تعذر تأكيد تسليم رسالة واتساب. حاول مرة أخرى بعد 60 ثانية.';
      }
      if (e.status == 503 || message.contains('otp_delivery_unavailable')) {
        return 'خدمة إرسال واتساب غير متاحة حالياً. حاول بعد قليل.';
      }
    }
    final typeName = e.runtimeType.toString();
    if (typeName.contains('Socket') || typeName.contains('ClientException')) {
      return 'لا يوجد اتصال بالإنترنت. تحقق من الشبكة وحاول مجدداً.';
    }
    return fallback;
  }
}

final authControllerProvider = StateNotifierProvider<AuthController, AuthState>(
  (ref) {
    return AuthController();
  },
);
