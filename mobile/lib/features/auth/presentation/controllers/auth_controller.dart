import 'dart:async';
import '../../../../core/services/push_notification_service.dart';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// hide AuthState: اسم يتعارض مع AuthState الخاصة بهذا المتحكم.
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

import '../../../../core/database/app_database.dart';
import '../../../../core/config/env.dart';
import '../../../../core/config/supabase_config.dart';
import '../../../../core/security/secure_auth_storage.dart';
import '../../../../core/sync/sync_engine.dart';
import '../../../../core/sync/user_contact_bootstrap.dart';
import '../validators/auth_validators.dart';
import '../../data/business_access_repository.dart';

/// متحكم المصادقة — «مُثبَت | MUTHBAT»
///
/// مصدر الحقيقة الوحيد للجلسة هو Supabase Auth (PKCE + refresh token):
/// `Supabase.auth.currentSession` + مستمع `onAuthStateChange`.
/// لا يُولَّد OTP ولا يُتحقق منه في جهاز العميل. الاستعادة المحلية تفتح فقط
/// بيانات الحساب المحفوظة على الجهاز، ولا تنشئ جلسة خادمية أو صلاحية جديدة.
///
/// ┌──────────────────────────────────────────────────────────────────┐
/// │ مسار OTP: Edge Functions تنشئ تحدياً خادمياً وتطلب من OpenWA       │
/// │ تسليم الرمز عبر WhatsApp، ثم تنشئ جلسة Supabase بعد التحقق.        │
/// │                                                                    │
/// │ الأسرار المطلوبة (خادمية فقط — تُضبط عبر `supabase secrets set`   │
/// │ لكل مشروع staging/prod):                                           │
/// │   OPENWA_BASE_URL / OPENWA_SESSION_ID / OPENWA_API_KEY             │
/// │ لا يوجد أي سر أو رمز OTP داخل هذا التطبيق.                         │
/// └──────────────────────────────────────────────────────────────────┘

enum AuthStatus {
  initial,
  loading,
  unauthenticated,
  otpSent,
  authenticated,
  localOnly,
  error,
}

/// سياق شاشة إدخال رمز التحقق: تسجيل جديد أم استرداد حساب.
enum AuthPendingAction { signup, recovery }

/// نتيجة الخروج المحلي وعدد العمليات المحفوظة، إن أمكن قراءته.
class SignOutResult {
  /// true إذا أُغلقت الجلسة فعلاً.
  final bool signedOut;

  /// يشمل طابور التاجر وطلبات العميل؛ null عند تعذر قراءة العدد.
  final int? preservedPendingCount;

  const SignOutResult({required this.signedOut, this.preservedPendingCount});
}

class AuthState {
  final AuthStatus status;
  final String? userId;
  final String? phoneNumber;
  final String? displayName;
  final String userType; // 'merchant' or 'customer'
  /// التاجر لا يدخل لوحة التحكم قبل إنشاء منشأته الأساسية.
  final bool requiresBusinessSetup;
  final String? activeBusinessId;
  final String? businessRole;
  final bool businessAccessChecked;
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
    this.activeBusinessId,
    this.businessRole,
    this.businessAccessChecked = false,
    this.errorMessage,
    this.challengeId,
    this.pendingPassword,
    this.recoveryOtpCode,
    this.pendingAction,
  });

  /// Local access never grants permission to send cloud requests.
  bool get hasLocalAccess =>
      status == AuthStatus.authenticated || status == AuthStatus.localOnly;

  AuthState copyWith({
    AuthStatus? status,
    String? userId,
    String? phoneNumber,
    String? displayName,
    String? userType,
    bool? requiresBusinessSetup,
    String? activeBusinessId,
    String? businessRole,
    bool? businessAccessChecked,
    bool clearBusinessAccess = false,
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
      activeBusinessId: clearBusinessAccess
          ? null
          : (activeBusinessId ?? this.activeBusinessId),
      businessRole: clearBusinessAccess
          ? null
          : (businessRole ?? this.businessRole),
      businessAccessChecked:
          businessAccessChecked ?? this.businessAccessChecked,
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

  /// Read-only snapshot for local navigation coordinators.
  AuthState get currentState => state;
  late final Future<void> _readyFuture;

  Future<void> get ready => _readyFuture;
  final _localReady = Completer<void>();
  Future<void> get localReady => _localReady.future;

  // نوع الحدث الخام هو AuthState الخاصة بـ supabase_flutter (مخفية عن الاستيراد).
  StreamSubscription<dynamic>? _authEventSubscription;
  bool _explicitSignOut = false;
  Future<SignOutResult>? _signOutFuture;
  Timer? _sessionExpiryTimer;
  int _sessionRevision = 0;
  int _profileRequest = 0;
  int _loginRequest = 0;
  Future<String?>? _businessAccessRefresh;
  String? _businessAccessRefreshOwner;
  bool _bootstrapCancelled = false;
  bool _initializingSession = true;

  void _requireAuthenticatedAccount() {
    final session = _auth.currentSession;
    if (_explicitSignOut ||
        session == null ||
        session.isExpired ||
        session.user.id != state.userId ||
        session.user.id != AppDatabase.instance.accountId) {
      throw const AuthException('Authentication session is no longer valid.');
    }
    _watchSessionExpiry();
  }

  Future<bool> _restoreLocalOwner() async {
    final revision = _sessionRevision;
    final business = await AppDatabase.instance.restoreRememberedOwner();
    if (!mounted || revision != _sessionRevision) return false;
    if (business == null ||
        await BusinessAccessRepository().locallyDenied(
          AppDatabase.instance.accountId!,
        )) {
      final profile = await AppDatabase.instance.restoreRememberedCustomer();
      if (!mounted || revision != _sessionRevision || profile == null) {
        return false;
      }
      final cachedAccess = await BusinessAccessRepository().cached(
        AppDatabase.instance.accountId!,
      );
      state = AuthState(
        status: AuthStatus.localOnly,
        userId: AppDatabase.instance.accountId,
        userType: cachedAccess != null
            ? 'merchant'
            : (profile['user_type'] as String?) ?? 'customer',
        requiresBusinessSetup:
            profile['user_type'] == 'merchant' && cachedAccess == null,
        activeBusinessId: cachedAccess?.businessId,
        businessRole: cachedAccess?.role,
        businessAccessChecked: true,
        displayName: profile['display_name'] as String?,
        phoneNumber: profile['phone'] as String?,
      );
      return true;
    }
    final ownerId = AppDatabase.instance.accountId;
    final profile = ownerId == null
        ? null
        : await AppDatabase.instance.getProfile(ownerId);
    if (!mounted || revision != _sessionRevision) return false;
    state = AuthState(
      status: AuthStatus.localOnly,
      userId: ownerId,
      userType: 'merchant',
      activeBusinessId: business['id'] as String,
      businessRole: 'owner',
      businessAccessChecked: true,
      // Keep the person's identity separate from the selected shop name.
      displayName: profile?['display_name'] as String? ?? 'حسابي',
      phoneNumber: profile?['phone'] as String?,
    );
    return true;
  }

  // ---------------------------------------------------------------------------
  // استعادة الجلسة (§3.4) — من Supabase SDK فقط، لا SharedPreferences
  // ---------------------------------------------------------------------------

  void _watchSessionExpiry() {
    _sessionExpiryTimer?.cancel();
    final session = _auth.currentSession;
    if (session == null || session.isExpired) {
      if (mounted && state.status == AuthStatus.authenticated) {
        state = state.copyWith(status: AuthStatus.localOnly);
      }
      return;
    }
    final expiresAt = session.expiresAt;
    if (expiresAt == null) return;
    final remaining = DateTime.fromMillisecondsSinceEpoch(expiresAt * 1000)
        // Match the installed gotrue session's 30-second expiry margin.
        .subtract(const Duration(seconds: 30))
        .add(const Duration(milliseconds: 1))
        .difference(DateTime.now());
    _sessionExpiryTimer = Timer(
      remaining.isNegative ? Duration.zero : remaining,
      _watchSessionExpiry,
    );
  }

  Future<void> _handleSessionEvent(AuthChangeEvent event) async {
    if (!mounted) return;
    if (event == AuthChangeEvent.signedOut) {
      _sessionRevision++;
      _sessionExpiryTimer?.cancel();
      if (_explicitSignOut) return;
      if (!await _restoreLocalOwner() && mounted) {
        state = const AuthState(status: AuthStatus.unauthenticated);
      }
      return;
    }
    _watchSessionExpiry();
    if (_initializingSession) return;
    if (event != AuthChangeEvent.signedIn &&
        event != AuthChangeEvent.tokenRefreshed) {
      return;
    }
    final session = _auth.currentSession;
    if (session == null ||
        session.isExpired ||
        state.status == AuthStatus.loading) {
      return;
    }

    try {
      await _loadProfile();
      _watchSessionExpiry();
      if (mounted && state.status == AuthStatus.authenticated) {
        SyncEngine.instance.triggerSync();
      }
    } catch (error) {
      debugPrint('[AuthController] session event failed: $error');
      if (mounted && !state.hasLocalAccess) {
        state = const AuthState(status: AuthStatus.unauthenticated);
      }
    }
  }

  Future<void> _initFromSupabaseSession() async {
    final bootstrapRevision = _sessionRevision;
    _authEventSubscription = _auth.onAuthStateChange.listen(
      (data) {
        unawaited(_handleSessionEvent(data.event));
      },
      onError: (Object error, StackTrace stackTrace) {
        // Offline refresh errors are stream errors, not proof of login.
        debugPrint('[AuthController] auth stream error: $error');
        if (mounted) _watchSessionExpiry();
      },
    );
    try {
      await _restoreLocalOwner();
      if (!_localReady.isCompleted) _localReady.complete();
      var session = _auth.currentSession;
      if (session != null && session.isExpired) {
        try {
          session = (await _auth.refreshSession().timeout(
            const Duration(seconds: 8),
          )).session;
        } catch (error) {
          debugPrint('[AuthController] refresh deferred: $error');
          session = null;
        }
      }
      if (!mounted ||
          _explicitSignOut ||
          _bootstrapCancelled ||
          bootstrapRevision != _sessionRevision) {
        return;
      }
      if (session != null && !session.isExpired) {
        await _loadProfile();
        _watchSessionExpiry();
        if (mounted && state.status == AuthStatus.authenticated) {
          SyncEngine.instance.triggerSync();
        }
      } else if (!state.hasLocalAccess) {
        state = const AuthState(status: AuthStatus.unauthenticated);
      } else {
        state = state.copyWith(status: AuthStatus.localOnly);
      }
    } catch (error) {
      debugPrint('[AuthController] session initialization failed: $error');
      if (mounted &&
          !_bootstrapCancelled &&
          bootstrapRevision == _sessionRevision) {
        state = state.hasLocalAccess
            ? state.copyWith(status: AuthStatus.localOnly)
            : const AuthState(status: AuthStatus.unauthenticated);
      }
    } finally {
      _initializingSession = false;
      if (!_localReady.isCompleted) _localReady.complete();
      if (mounted &&
          !_bootstrapCancelled &&
          bootstrapRevision == _sessionRevision) {
        _watchSessionExpiry();
        // A refresh may finish after our timeout while initialization is busy.
        if (state.status == AuthStatus.localOnly &&
            _auth.currentSession != null &&
            !_auth.currentSession!.isExpired) {
          unawaited(_handleSessionEvent(AuthChangeEvent.tokenRefreshed));
        }
      }
    }
  }

  @override
  void dispose() {
    _sessionExpiryTimer?.cancel();
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
      if (!EnvConfig.phoneVerificationEnabled) {
        return await _registerWithPhonePassword(
          name: name,
          phone: normalizedPhone,
          password: password,
          userType: userType,
        );
      }
      if (EnvConfig.allowStagingDirectAuth) {
        return await _registerDirectlyForStaging(
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
          fallback: EnvConfig.phoneVerificationEnabled
              ? 'تعذر إرسال رمز التحقق عبر واتساب. تحقق من الشبكة.'
              : 'تعذر إنشاء الحساب. تحقق من البيانات والاتصال وحاول مجددًا.',
        ),
      );
      return false;
    }
  }

  Future<bool> _registerWithPhonePassword({
    required String name,
    required String phone,
    required String password,
    required String userType,
  }) async {
    final response = await Supabase.instance.client.functions
        .invoke(
          'phone-password-signup',
          body: {
            'phone': phone,
            'password': password,
            'displayName': name.trim(),
            'userType': userType,
          },
        )
        .timeout(const Duration(seconds: 25));
    if (response.data is! Map || response.data['success'] != true) {
      throw const AuthException('تعذر إنشاء الحساب. حاول مجددًا.');
    }
    await _signInWithPhoneOrEmail(phone, password);
    await _loadProfile();
    _requireAuthenticatedAccount();
    state = state.copyWith(
      status: AuthStatus.authenticated,
      clearPendingAction: true,
    );
    SyncEngine.instance.triggerSync();
    return true;
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
    _requireAuthenticatedAccount();
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

      _requireAuthenticatedAccount();
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
    _sessionRevision++;
    final revision = _sessionRevision;
    final drain = SyncEngine.instance.pauseAndDrain();
    try {
      // Pause new sync work immediately, but overlap the password handshake
      // with draining the old account. Rebinding still waits for both.
      final results = await Future.wait<AuthResponse?>([
        _auth
            .signInWithPassword(phone: e164, password: password)
            .timeout(const Duration(seconds: 25)),
        drain.then<AuthResponse?>((_) => null),
      ]);
      final response = results.first!;
      if (!mounted || revision != _sessionRevision || _explicitSignOut) {
        throw const AuthException('Sign-in was superseded.');
      }
      if (response.user != null) {
        await AppDatabase.instance.forgetRememberedOwner();
        await AppDatabase.instance.bindAccount(response.user!.id);
        await _cacheLocalIdentity(response.user!);
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
    bool merchantMode = false,
  }) async {
    final attempt = ++_loginRequest;
    final previous = state;
    state = state.copyWith(status: AuthStatus.loading, errorMessage: null);

    try {
      final passwordError = AuthValidators.passwordError(password);
      if (passwordError != null) {
        state = state.copyWith(
          status:
              previous.hasLocalAccess &&
                  AppDatabase.instance.accountId == previous.userId
              ? AuthStatus.localOnly
              : AuthStatus.error,
          errorMessage: passwordError,
        );
        return false;
      }
      await _signInWithPhoneOrEmail(phone, password);
      if (!mounted || attempt != _loginRequest) return false;

      final localOpened = await _openSignedInLocalWorkspace(
        requireBusinessAccess: merchantMode,
      );
      // A merchant on a new device needs a confirmed destination first.
      // Existing notebooks and the customer workspace open from the device.
      if (!localOpened) await _loadProfile();

      if (!mounted || attempt != _loginRequest) return false;
      _requireAuthenticatedAccount();
      state = state.copyWith(
        status: AuthStatus.authenticated,
        clearPendingAction: true,
      );

      SyncEngine.instance.triggerSync();
      unawaited(
        _finishLoginInBackground(
          _auth.currentUser!.id,
          _sessionRevision,
          refreshProfile: localOpened,
        ),
      );
      return true;
    } catch (e) {
      debugPrint('[AuthController] loginWithPassword error: $e');
      if (!mounted || attempt != _loginRequest) return false;
      state = state.copyWith(
        status:
            previous.hasLocalAccess &&
                AppDatabase.instance.accountId == previous.userId
            ? AuthStatus.localOnly
            : AuthStatus.error,
        errorMessage: _mapAuthError(
          e,
          fallback:
              'رقم الهاتف أو كلمة السر غير صحيحة. يرجى المحاولة مرة أخرى.',
        ),
      );
      return false;
    }
  }

  Future<bool> _openSignedInLocalWorkspace({
    required bool requireBusinessAccess,
  }) async {
    final user = _auth.currentUser;
    final revision = _sessionRevision;
    final db = AppDatabase.instance;
    if (user == null || db.accountId != user.id) return false;
    final profile = await db.getProfile(user.id);
    final repository = BusinessAccessRepository();
    BusinessAccess? access = await repository.cached(user.id);
    final denied = await repository.locallyDenied(user.id);
    if (denied) access = null;
    if (access == null && !denied) {
      final business = await db.getBusinessByOwnerId(user.id);
      if (business != null) {
        access = BusinessAccess(
          businessId: business['id'] as String,
          role: 'owner',
        );
      }
    }
    // Cached employee grants are refreshed before entering the merchant UI.
    // Only owners can reopen their own device notebook immediately.
    if (requireBusinessAccess && access?.role != 'owner') return false;
    if (!mounted ||
        _explicitSignOut ||
        revision != _sessionRevision ||
        _auth.currentUser?.id != user.id ||
        db.accountId != user.id) {
      return false;
    }
    state = AuthState(
      status: AuthStatus.authenticated,
      userId: user.id,
      displayName: profile?['display_name'] as String? ?? 'حسابي',
      phoneNumber: user.phone,
      userType: access != null ? 'merchant' : 'customer',
      activeBusinessId: access?.businessId,
      businessRole: access?.role,
      businessAccessChecked: access?.role == 'owner',
    );
    return true;
  }

  Future<void> _finishLoginInBackground(
    String owner,
    int revision, {
    required bool refreshProfile,
  }) async {
    bool current() =>
        mounted &&
        !_explicitSignOut &&
        revision == _sessionRevision &&
        _auth.currentUser?.id == owner &&
        AppDatabase.instance.accountId == owner;
    if (!current()) return;
    try {
      await Future.wait([
        _bootstrapUserContact(),
        if (refreshProfile) _loadProfile(),
      ]);
    } catch (error) {
      // Background hydration cannot turn a successful password login into an error.
      debugPrint(
        '[AuthController] post-login refresh deferred: ${error.runtimeType}',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // استرداد الحساب: OTP عبر OpenWA → جلسة → كلمة سر جديدة
  // ---------------------------------------------------------------------------

  /// إرسال رمز استرداد عبر واتساب (OpenWA).
  Future<bool> sendRecoveryOtp({required String phone}) async {
    if (!EnvConfig.phoneVerificationEnabled) {
      state = state.copyWith(
        status: AuthStatus.error,
        errorMessage: 'استعادة كلمة المرور غير متاحة حاليًا. تواصل مع الدعم.',
      );
      return false;
    }
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

      _requireAuthenticatedAccount();
      state = state.copyWith(
        status: AuthStatus.authenticated,
        recoveryOtpCode: '',
        clearPendingAction: true,
      );

      SyncEngine.instance.triggerSync();
      return true;
    } catch (e) {
      debugPrint('[AuthController] completePasswordReset error: $e');
      if (e is FunctionException && e.toString().contains('invalid_otp')) {
        state = state.copyWith(
          status: AuthStatus.otpSent,
          recoveryOtpCode: '',
          errorMessage:
              'رمز التحقق غير صحيح أو منتهي الصلاحية. أدخل الرمز الأحدث أو اطلب رمزًا جديدًا.',
        );
        return false;
      }
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
    if (!EnvConfig.phoneVerificationEnabled) return false;
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
  // الخروج المحلي مع الاحتفاظ بالبيانات والطوابير المشفرة لكل حساب.
  // ---------------------------------------------------------------------------

  /// Ends this device session and locks its database. Local data and queued
  /// work are preserved for the same account; no discard or global sign-out.
  Future<SignOutResult> signOut() {
    final pending = _signOutFuture;
    if (pending != null) return pending;
    final operation = _performSignOut();
    _signOutFuture = operation;
    return operation.whenComplete(() {
      _signOutFuture = null;
    });
  }

  Future<SignOutResult> _performSignOut() async {
    int? preservedPendingCount;
    try {
      _explicitSignOut = true;
      _loginRequest++;
      _sessionRevision++;
      _sessionExpiryTimer?.cancel();
      await SyncEngine.instance.pauseAndDrain();
      if (AppDatabase.instance.accountId != null) {
        try {
          preservedPendingCount =
              await AppDatabase.instance.getPendingMutationsCount() +
              await AppDatabase.instance.getDeadLetterCount();
          final db = await AppDatabase.instance.database;
          final exists = await db.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='customer_outbox'",
          );
          if (exists.isNotEmpty) {
            final rows = await db.rawQuery(
              'SELECT COUNT(*) AS count FROM customer_outbox',
            );
            preservedPendingCount += (rows.first['count'] as num).toInt();
          }
        } catch (_) {
          preservedPendingCount = null;
        }
      }
      await PushNotificationService.instance.deactivateDeviceToken();
      await _auth.signOut(scope: SignOutScope.local);
      // Await durable removal too: SDK auth stream persistence is asynchronous.
      final vault = SecureAuthVault(supabaseUrl: SupabaseConfig.effectiveUrl);
      await vault.remove(vault.legacySessionKey);
      await AppDatabase.instance.forgetRememberedOwner();
      await AppDatabase.instance.lockAccount();

      state = const AuthState(status: AuthStatus.unauthenticated);
      return SignOutResult(
        signedOut: true,
        preservedPendingCount: preservedPendingCount,
      );
    } catch (e) {
      debugPrint('[AuthController] signOut error: $e');
      // فشل الخروج أو المسح لا يمنح إذناً بحذف العمليات غير المزامنة.
      // لا نعلن نجاح الخروج إذا لم تكتمل خطواته.
      state = state.copyWith(
        status: _auth.currentSession != null && !_auth.currentSession!.isExpired
            ? AuthStatus.authenticated
            : AppDatabase.instance.accountId == state.userId &&
                  state.userId != null
            ? AuthStatus.localOnly
            : AuthStatus.unauthenticated,
        errorMessage:
            'تعذر إكمال تسجيل الخروج. احتُفظ بالبيانات المحلية؛ حاول مجدداً.',
      );
      return const SignOutResult(signedOut: false);
    } finally {
      _explicitSignOut = false;
      if (mounted) _watchSessionExpiry();
      SyncEngine.instance.resume();
    }
  }

  void reset() {
    _loginRequest++;
    _sessionRevision++;
    _profileRequest++;
    _bootstrapCancelled = true;
    state = state.hasLocalAccess
        ? state.copyWith(status: AuthStatus.localOnly)
        : const AuthState(status: AuthStatus.unauthenticated);
  }

  /// Only cached ownership determines local workspace availability; this is
  /// not a server role grant or a change to the customer's personal identity.
  Future<void> refreshLocalBusinessAccess() async {
    final owner = state.userId;
    if (owner == null || AppDatabase.instance.accountId != owner) return;
    if (await BusinessAccessRepository().locallyDenied(owner)) {
      if (mounted && state.userId == owner) {
        state = state.copyWith(
          clearBusinessAccess: true,
          businessAccessChecked: true,
          requiresBusinessSetup: false,
        );
      }
      return;
    }
    var access = await BusinessAccessRepository().cached(owner);
    if (access == null) {
      final business = await AppDatabase.instance.getBusinessByOwnerId(owner);
      if (business != null) {
        access = BusinessAccess(
          businessId: business['id'] as String,
          role: 'owner',
        );
      }
    }
    if (!mounted ||
        state.userId != owner ||
        AppDatabase.instance.accountId != owner ||
        access == null) {
      return;
    }
    state = state.copyWith(
      userType: 'merchant',
      requiresBusinessSetup: false,
      activeBusinessId: access.businessId,
      businessRole: access.role,
      businessAccessChecked: true,
    );
  }

  /// Rechecks cloud membership when the account workspace selector is opened.
  /// The customer workspace selection remains independent from merchant access.
  Future<String?> refreshCloudBusinessAccess({
    bool retryAfterDatabaseRecovery = true,
  }) {
    final owner = state.userId;
    final pending = _businessAccessRefresh;
    if (pending != null) {
      if (_businessAccessRefreshOwner == owner) return pending;
      return pending.then(
        (_) => refreshCloudBusinessAccess(
          retryAfterDatabaseRecovery: retryAfterDatabaseRecovery,
        ),
      );
    }

    late final Future<String?> tracked;
    tracked =
        _refreshCloudBusinessAccess(
          owner: owner,
          retryAfterDatabaseRecovery: retryAfterDatabaseRecovery,
        ).whenComplete(() {
          if (identical(_businessAccessRefresh, tracked)) {
            _businessAccessRefresh = null;
            _businessAccessRefreshOwner = null;
          }
        });
    _businessAccessRefreshOwner = owner;
    _businessAccessRefresh = tracked;
    return tracked;
  }

  Future<String?> _refreshCloudBusinessAccess({
    required String? owner,
    required bool retryAfterDatabaseRecovery,
  }) async {
    if (owner == null || !state.hasLocalAccess) {
      return null;
    }
    final activeSession = _auth.currentSession;
    final hasValidCloudSession =
        activeSession != null &&
        !activeSession.isExpired &&
        activeSession.user.id == owner &&
        _auth.currentUser?.id == owner;
    if (!hasValidCloudSession) {
      // Offline/local-only workspace switching must use this account's local
      // notebook access, and must not depend on a cloud session.
      try {
        await SyncEngine.instance.pauseAndDrain();
        try {
          await AppDatabase.instance.bindAccount(owner);
          var access = await BusinessAccessRepository().cached(owner);
          if (access == null &&
              !await BusinessAccessRepository().locallyDenied(owner)) {
            final owned = await AppDatabase.instance.getBusinessByOwnerId(
              owner,
            );
            if (owned != null) {
              access = BusinessAccess(
                businessId: owned['id'] as String,
                role: 'owner',
              );
            }
          }
          if (!mounted || state.userId != owner) return null;
          state = state.copyWith(
            userType: access == null ? state.userType : 'merchant',
            requiresBusinessSetup: false,
            activeBusinessId: access?.businessId,
            businessRole: access?.role,
            businessAccessChecked: true,
            clearBusinessAccess: access == null,
          );
          return null;
        } finally {
          SyncEngine.instance.resume();
        }
      } catch (error) {
        debugPrint(
          '[AuthController] local business access lookup failed: $error',
        );
        return 'تعذر فتح دفتر المتجر المحفوظ على هذا الجهاز.';
      }
    }
    bool current() =>
        mounted &&
        state.userId == owner &&
        state.hasLocalAccess &&
        _auth.currentUser?.id == owner;
    try {
      // Rebind even when the account id matches: a background WorkManager
      // engine may have closed the native SQLite handle behind this isolate.
      await SyncEngine.instance.pauseAndDrain();
      try {
        await AppDatabase.instance.bindAccount(owner);
      } finally {
        SyncEngine.instance.resume();
      }
      if (!current()) return null;
      final access = await BusinessAccessRepository().load(
        owner,
        isCurrent: current,
      );
      if (!current()) return null;
      final profile = await AppDatabase.instance.getProfile(owner);
      if (!current()) return null;
      final profileType = profile?['user_type'] as String? ?? state.userType;
      state = state.copyWith(
        status: AuthStatus.authenticated,
        userType: access == null ? profileType : 'merchant',
        requiresBusinessSetup: access == null && profileType == 'merchant',
        activeBusinessId: access?.businessId,
        businessRole: access?.role,
        businessAccessChecked: true,
        clearBusinessAccess: access == null,
      );
      return null;
    } catch (error) {
      debugPrint(
        '[AuthController] manual business access refresh failed: $error',
      );
      if (retryAfterDatabaseRecovery &&
          error.toString().contains('database_closed') &&
          current()) {
        try {
          await AppDatabase.instance.reopenAccount(owner);
          if (current()) {
            return _refreshCloudBusinessAccess(
              owner: owner,
              retryAfterDatabaseRecovery: false,
            );
          }
        } catch (recoveryError) {
          debugPrint(
            '[AuthController] database recovery failed: $recoveryError',
          );
        }
      }
      if (!current()) return null;
      return 'تعذر تحديث عضوية النشاط. تحقق من الاتصال وحاول مرة أخرى.';
    }
  }

  /// Rebinds the current account and restores its personal identity before
  /// entering the customer workspace. Merchant workspace names belong to the
  /// business header and must never replace the user's profile name.
  Future<void> prepareCustomerWorkspace() async {
    final owner = state.userId;
    if (owner == null || !state.hasLocalAccess) {
      throw StateError('سجّل الدخول لفتح حساب العميل.');
    }
    bool current() => mounted && state.userId == owner && state.hasLocalAccess;

    // Workspace selection never waits for a cloud request or an in-flight sync.
    if (AppDatabase.instance.accountId != owner) {
      throw StateError('تغير الحساب المحلي');
    }
    final profile = await AppDatabase.instance.getProfile(owner);
    if (!current()) return;
    final name = (profile?['display_name'] as String?)?.trim();
    final phone = (profile?['phone'] as String?)?.trim();
    state = state.copyWith(
      displayName: name?.isNotEmpty == true ? name : 'حساب العميل',
      phoneNumber: phone?.isNotEmpty == true ? phone : _auth.currentUser?.phone,
    );
  }

  /// Select the exact imported workspace only after server membership checks.
  /// This also persists the preference used on the next authenticated login.
  Future<void> activateImportedBusiness(String businessId) async {
    final owner = state.userId;
    if (owner == null || AppDatabase.instance.accountId != owner) {
      throw StateError('تغيّر الحساب. سجّل الدخول لاستكمال فتح الدفتر.');
    }
    bool current() =>
        mounted &&
        state.userId == owner &&
        AppDatabase.instance.accountId == owner;
    final access = await BusinessAccessRepository().load(
      owner,
      preferredBusinessId: businessId,
      requireOwnership: true,
      isCurrent: current,
    );
    if (!current() ||
        access == null ||
        access.businessId != businessId ||
        access.role != 'owner') {
      throw StateError('تعذر تأكيد ملكية النشاط المنقول.');
    }
    state = state.copyWith(
      userType: 'merchant',
      requiresBusinessSetup: false,
      activeBusinessId: access.businessId,
      businessRole: access.role,
      businessAccessChecked: true,
    );
  }

  // ---------------------------------------------------------------------------
  // أدوات داخلية
  // ---------------------------------------------------------------------------

  /// قراءة الملف الشخصي من public.profiles عبر RLS، مع تخزين واسترجاع محلي (SQLite) للعمل بدون إنترنت.
  /// Persist UI identity before network lookups, including unfinished merchants.
  /// This cache grants no cloud role or business access.
  Future<void> _cacheLocalIdentity(User user) async {
    final db = AppDatabase.instance;
    if (db.accountId != user.id) return;
    final cached = await db.getProfile(user.id);
    final type = cached?['user_type'] ?? user.userMetadata?['user_type'];
    await db.saveProfile({
      'id': user.id,
      'display_name':
          cached?['display_name'] ??
          user.userMetadata?['display_name'] ??
          'مستخدم',
      'user_type': type == 'merchant' ? 'merchant' : 'customer',
      'phone': user.phone ?? cached?['phone'],
      'updated_at': cached?['updated_at'] ?? DateTime.now().toIso8601String(),
    });
    await db.rememberCustomer();
    await db.rememberOwner();
  }

  Future<void> _loadProfile() async {
    final user = _auth.currentUser;
    final revision = _sessionRevision;
    final request = ++_profileRequest;
    bool current() =>
        mounted &&
        !_explicitSignOut &&
        revision == _sessionRevision &&
        request == _profileRequest &&
        _auth.currentUser?.id == user?.id;
    if (user == null || !current()) return;
    await AppDatabase.instance.forgetRememberedOwner();
    if (AppDatabase.instance.accountId != user.id) {
      await SyncEngine.instance.pauseAndDrain();
      try {
        await AppDatabase.instance.bindAccount(user.id);
      } finally {
        SyncEngine.instance.resume();
      }
    }

    // Reopen a stale handle when a background Flutter engine closed the
    // account database without changing this isolate's account id.
    await AppDatabase.instance.bindAccount(user.id);

    if (!current()) return;
    await _cacheLocalIdentity(user);
    if (!current()) return;
    final localProfile = await AppDatabase.instance.getProfile(user.id);
    String? displayName = localProfile?['display_name'] as String?;
    String userType = (localProfile?['user_type'] as String?) ?? 'customer';
    final now = DateTime.now().toIso8601String();

    Future<void> refreshProfile() async {
      try {
        final row = await Supabase.instance.client
            .from('profiles')
            .select('display_name, user_type')
            .eq('id', user.id)
            .maybeSingle()
            .timeout(const Duration(seconds: 8));
        if (!current() || AppDatabase.instance.accountId != user.id) return;
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
        if (!current() || AppDatabase.instance.accountId != user.id) return;
        // محاولة القراءة من الكاش المحلي (SQLite) عند انقطاع الإنترنت
        try {
          final cached = await AppDatabase.instance.getProfile(user.id);
          if (cached != null) {
            displayName = cached['display_name'] as String?;
            userType = (cached['user_type'] as String?) ?? userType;
          }
        } catch (_) {}
        displayName ??= (user.userMetadata?['display_name'] as String?);
      }
    }

    if (!current()) return;
    BusinessAccess? access;
    var accessChecked = false;
    Future<void> refreshAccess() async {
      try {
        access = await BusinessAccessRepository().load(
          user.id,
          isCurrent: current,
        );
        accessChecked = true;
      } catch (error) {
        debugPrint('[AuthController] business access lookup deferred: $error');
        if (!current() || AppDatabase.instance.accountId != user.id) return;
        access = await BusinessAccessRepository().cached(user.id);
        final owner = await AppDatabase.instance.getBusinessByOwnerId(user.id);
        if (access == null &&
            owner != null &&
            !await BusinessAccessRepository().locallyDenied(user.id)) {
          access = BusinessAccess(
            businessId: owner['id'] as String,
            role: 'owner',
          );
        }
        // Cached employee roles must not authorize online screens after a failed
        // membership lookup. Only the owner's local notebook remains available.
        accessChecked = access?.role == 'owner';
      }
    }

    // Independent reads: first-time merchant login need not pay both latencies
    // sequentially. Attach both error handlers immediately via Future.wait.
    await Future.wait([refreshProfile(), refreshAccess()]);
    if (!current() || AppDatabase.instance.accountId != user.id) return;
    if (access != null) userType = 'merchant';
    final requiresBusinessSetup =
        accessChecked && access == null && userType == 'merchant';
    await AppDatabase.instance.rememberCustomer();
    await AppDatabase.instance.rememberOwner();

    if (!current() ||
        revision != _sessionRevision ||
        _explicitSignOut ||
        _auth.currentUser?.id != user.id ||
        AppDatabase.instance.accountId != user.id) {
      return;
    }
    await AppDatabase.instance.saveProfile({
      'id': user.id,
      'display_name': displayName ?? 'مستخدم',
      'user_type': userType,
      'phone': user.phone,
      'updated_at': now,
    });
    if (!current() || AppDatabase.instance.accountId != user.id) return;
    final session = _auth.currentSession;
    state = state.copyWith(
      status: session != null && !session.isExpired
          ? AuthStatus.authenticated
          : AuthStatus.localOnly,
      userId: user.id,
      phoneNumber: user.phone ?? state.phoneNumber,
      displayName: displayName ?? state.displayName,
      userType: userType,
      requiresBusinessSetup: requiresBusinessSetup,
      activeBusinessId: access?.businessId,
      businessRole: access?.role,
      businessAccessChecked: accessChecked,
      clearBusinessAccess: access == null,
    );
    _watchSessionExpiry();
  }

  /// idempotent من جهة الخادم — الفشل هنا لا يمنع الدخول ويُعاد عند الدخول التالي.
  Future<void> _bootstrapUserContact() async {
    if (_auth.currentUser?.appMetadata['phone_verification_bypassed'] == true &&
        !EnvConfig.allowStagingUnverifiedPhoneLinks) {
      return;
    }
    try {
      await bootstrapUserContact(
        Supabase.instance.client,
      ).timeout(const Duration(seconds: 8));
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
      if (e.status == 0) {
        return 'تعذر الاتصال بالخادم. تحقق من الإنترنت أو جرّب شبكة أخرى، ثم أعد المحاولة.';
      }
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
