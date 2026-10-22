import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../../data/customer_repository.dart';
import '../../data/customer_cache.dart';
import '../../data/customer_local_store.dart';
import '../../../auth/presentation/controllers/auth_controller.dart';
import '../../data/models/customer_summary_model.dart';

/// حالة شاشة العميل الرئيسية — بيانات حقيقية من الخادم فقط، بلا أي نصوص ثابتة.
class CustomerHomeState {
  final List<Map<String, dynamic>> outbox;
  final bool isCached;
  final String? updatedAt;
  final bool isLoading;
  final bool hasCustomerAccount; // false = لا سجل customers مرتبط بالمستخدم
  final String? customerId;
  final String? errorMessage; // خطأ التحميل العام (يُعرض مع زر إعادة المحاولة)
  final String? phoneLinkError;
  final bool requiresPhoneVerification;
  final List<CustomerBusinessSummary> summaries;
  final List<CustomerLinkRequestModel> linkRequests;
  final List<CustomerPendingEntry> pendingEntries;

  const CustomerHomeState({
    this.outbox = const [],
    this.isCached = false,
    this.updatedAt,
    this.isLoading = false,
    this.hasCustomerAccount = true,
    this.customerId,
    this.errorMessage,
    this.phoneLinkError,
    this.requiresPhoneVerification = false,
    this.summaries = const [],
    this.linkRequests = const [],
    this.pendingEntries = const [],
  });

  CustomerHomeState copyWith({
    List<Map<String, dynamic>>? outbox,
    bool? isCached,
    String? updatedAt,
    bool? isLoading,
    bool? hasCustomerAccount,
    String? customerId,
    bool clearCustomerId = false,
    String? errorMessage,
    bool clearError = false,
    String? phoneLinkError,
    bool clearPhoneLinkError = false,
    bool? requiresPhoneVerification,
    List<CustomerBusinessSummary>? summaries,
    List<CustomerLinkRequestModel>? linkRequests,
    List<CustomerPendingEntry>? pendingEntries,
  }) {
    return CustomerHomeState(
      outbox: outbox ?? this.outbox,
      isCached: isCached ?? this.isCached,
      updatedAt: updatedAt ?? this.updatedAt,
      isLoading: isLoading ?? this.isLoading,
      hasCustomerAccount: hasCustomerAccount ?? this.hasCustomerAccount,
      customerId: clearCustomerId ? null : (customerId ?? this.customerId),
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      phoneLinkError: clearPhoneLinkError
          ? null
          : (phoneLinkError ?? this.phoneLinkError),
      requiresPhoneVerification:
          requiresPhoneVerification ?? this.requiresPhoneVerification,
      summaries: summaries ?? this.summaries,
      linkRequests: linkRequests ?? this.linkRequests,
      pendingEntries: pendingEntries ?? this.pendingEntries,
    );
  }
}

class CustomerController extends StateNotifier<CustomerHomeState> {
  int _loadVersion = 0;
  int _activeLoads = 0;
  DateTime? _lastSuccessfulLoadAt;
  final _cache = CustomerCache();
  final CustomerRepository _repository;
  final DateTime Function() _now;

  CustomerController(this._repository, {DateTime Function()? now})
    : _now = now ?? DateTime.now,
      super(const CustomerHomeState());

  Future<void> restoreLocal() async {
    final owner = _repository.userId;
    if (!mounted || owner == null) return;
    try {
      final saved = await _cache.read(owner, 'home');
      final outbox = await _repository.pendingActions();
      if (!mounted || _repository.userId != owner || saved == null) return;
      final updated = saved['updated_at'] as String?;
      if (updated == null ||
          (state.updatedAt != null &&
              DateTime.parse(
                updated,
              ).isBefore(DateTime.parse(state.updatedAt!)))) {
        return;
      }
      state = state.copyWith(
        isLoading: false,
        updatedAt: updated,
        customerId: saved['customer_id'] as String?,
        clearCustomerId: saved['customer_id'] == null,
        hasCustomerAccount: saved['customer_id'] != null,
        outbox: outbox,
        summaries: (saved['summaries'] as List)
            .map(
              (e) =>
                  CustomerBusinessSummary.fromMap(Map<String, dynamic>.from(e)),
            )
            .toList(),
        linkRequests: (saved['requests'] as List)
            .map(
              (e) => CustomerLinkRequestModel.fromMap(
                Map<String, dynamic>.from(e),
              ),
            )
            .toList(),
        pendingEntries: (saved['entries'] as List)
            .map(
              (e) => CustomerPendingEntry.fromMap(Map<String, dynamic>.from(e)),
            )
            .toList(),
      );
    } catch (_) {
      /* The next synchronization repairs an invalid projection. */
    }
  }

  void refreshIfIdle({bool onlyPending = false}) {
    if (!mounted || _activeLoads > 0) return;
    final phoneLinkNeedsRetry =
        state.phoneLinkError != null || state.requiresPhoneVerification;
    final last = _lastSuccessfulLoadAt;
    if (!phoneLinkNeedsRetry &&
        last != null &&
        _now().difference(last) < const Duration(seconds: 45)) {
      return;
    }
    if (onlyPending && !state.outbox.any((e) => e['status'] == 'pending')) {
      return;
    }
    unawaited(load());
  }

  /// تحميل كل بيانات الشاشة من الخادم (الملخص + طلبات الربط + القيود المعلقة)
  Future<void> load({bool force = false}) async {
    if (!mounted || (_activeLoads > 0 && !force)) return;
    if (!force &&
        state.phoneLinkError == null &&
        !state.requiresPhoneVerification &&
        _lastSuccessfulLoadAt != null &&
        _now().difference(_lastSuccessfulLoadAt!) <
            const Duration(seconds: 45)) {
      return;
    }
    final version = ++_loadVersion;
    final owner = _repository.userId;
    if (owner == null) {
      state = const CustomerHomeState(hasCustomerAccount: false);
      return;
    }
    _activeLoads++;
    bool current() =>
        mounted && version == _loadVersion && _repository.userId == owner;
    // Keep visible data on screen during background refresh; only initial loads
    // need the full-screen loading state.
    final hasVisibleData =
        state.updatedAt != null ||
        state.summaries.isNotEmpty ||
        state.customerId != null;
    state = state.copyWith(isLoading: !hasVisibleData, clearError: true);

    try {
      try {
        final saved = await _cache.read(owner, 'home');
        if (!current()) return;
        if (saved != null && !hasVisibleData) {
          state = CustomerHomeState(
            isLoading: false,
            isCached: true,
            updatedAt: saved['updated_at'] as String?,
            customerId: saved['customer_id'] as String?,
            hasCustomerAccount: saved['customer_id'] != null,
            summaries: (saved['summaries'] as List)
                .map(
                  (e) => CustomerBusinessSummary.fromMap(
                    Map<String, dynamic>.from(e),
                  ),
                )
                .toList(),
            linkRequests: (saved['requests'] as List)
                .map(
                  (e) => CustomerLinkRequestModel.fromMap(
                    Map<String, dynamic>.from(e),
                  ),
                )
                .toList(),
            pendingEntries: (saved['entries'] as List)
                .map(
                  (e) => CustomerPendingEntry.fromMap(
                    Map<String, dynamic>.from(e),
                  ),
                )
                .toList(),
          );
        }
      } catch (_) {
        /* A corrupt/unavailable cache must not prevent an online load. */
      }
      final queued = await _repository.pendingActions();
      if (!current()) return;
      state = state.copyWith(outbox: queued);
      // Reads do not depend on phone linking or delivery of queued commands.
      // Publish the first authorized snapshot while those requests are in flight.
      final maintenance = Future.wait<bool>([
        () async {
          if (!queued.any((e) => e['status'] == 'pending')) return false;
          try {
            await _repository.flushOutbox();
            if (!current()) return false;
            final remaining = await _repository.pendingActions();
            if (current()) state = state.copyWith(outbox: remaining);
            return true;
          } catch (_) {
            return false;
          }
        }(),
        () async {
          String? phoneLinkError;
          var requiresPhoneVerification = false;
          try {
            await _repository.refreshPhoneLinks();
          } catch (e) {
            requiresPhoneVerification = e is CustomerPhoneVerificationRequired;
            phoneLinkError = e
                .toString()
                .replaceFirst('Exception: ', '')
                .replaceFirst('Bad state: ', '');
          }
          if (!current()) return false;
          state = state.copyWith(
            phoneLinkError: phoneLinkError,
            clearPhoneLinkError: phoneLinkError == null,
            requiresPhoneVerification: requiresPhoneVerification,
          );
          return phoneLinkError == null;
        }(),
      ]);
      final firstSnapshot = await _repository.fetchHomeSnapshot();
      if (!current()) return;
      await _showSnapshot(owner, firstSnapshot);
      final changed = await maintenance;
      if (!current() || !changed.any((value) => value)) return;
      // A successful claim/command may have changed relationships or entries.
      final snapshot = await _repository.fetchHomeSnapshot();
      if (!current()) return;
      await _showSnapshot(owner, snapshot);
    } catch (e) {
      if (!current()) return;
      state = state.copyWith(
        isLoading: false,
        isCached: state.updatedAt != null,
        errorMessage: e.toString().replaceFirst('Exception: ', ''),
      );
    } finally {
      _activeLoads--;
    }
  }

  Future<void> _showSnapshot(
    String owner,
    CustomerReadSnapshot snapshot,
  ) async {
    _lastSuccessfulLoadAt = _now();
    state = state.copyWith(
      isCached: false,
      updatedAt: snapshot.updatedAt,
      isLoading: false,
      hasCustomerAccount: snapshot.customerId != null,
      customerId: snapshot.customerId,
      clearCustomerId: snapshot.customerId == null,
      summaries: snapshot.summaries,
      linkRequests: snapshot.requests,
      pendingEntries: snapshot.entries
          .map(CustomerPendingEntry.fromMap)
          .toList(),
    );
    try {
      await _repository.local.saveHome(owner, snapshot);
    } catch (_) {
      /* The next synchronization retries persistence. */
    }
  }

  /// الرد على طلب ربط — يعيد true عند النجاح، ويرمي رسالة الخطأ للواجهة عند الفشل
  Future<bool> respondToLinkRequest(String requestId, bool accept) async {
    final owner = _repository.userId;
    try {
      await _repository.respondLinkRequest(
        requestId: requestId,
        accept: accept,
      );
      if (!mounted || owner != _repository.userId) return false;
      final pending = await _repository.pendingActions();
      if (!mounted || owner != _repository.userId) return false;
      state = state.copyWith(outbox: pending);
      unawaited(load(force: true));
      return true;
    } catch (e) {
      if (!mounted || owner != _repository.userId) return false;
      state = state.copyWith(
        errorMessage: e.toString().replaceFirst('Exception: ', ''),
      );
      return false;
    }
  }

  /// تأكيد قيد مالي معلق — يحدّث القوائم بعد النجاح
  Future<bool> confirmEntry(String entryId) async {
    final owner = _repository.userId;
    try {
      await _repository.confirmEntry(entryId);
      if (!mounted || owner != _repository.userId) return false;
      // Keep the entry visible until the server confirms the queued request.
      final pending = await _repository.pendingActions();
      if (!mounted || owner != _repository.userId) return false;
      state = state.copyWith(outbox: pending);
      unawaited(load(force: true));
      return true;
    } catch (e) {
      if (!mounted || owner != _repository.userId) return false;
      state = state.copyWith(
        errorMessage: e.toString().replaceFirst('Exception: ', ''),
      );
      return false;
    }
  }

  Future<bool> openDispute({
    required String entryId,
    required String reason,
    required String description,
  }) async {
    final owner = _repository.userId;
    try {
      await _repository.openDispute(
        entryId: entryId,
        reason: reason,
        description: description,
      );
      if (!mounted || owner != _repository.userId) return false;
      final pending = await _repository.pendingActions();
      if (!mounted || owner != _repository.userId) return false;
      state = state.copyWith(outbox: pending);
      unawaited(load(force: true));
      return true;
    } catch (e) {
      if (!mounted || owner != _repository.userId) return false;
      state = state.copyWith(
        errorMessage: e.toString().replaceFirst('Exception: ', ''),
      );
      return false;
    }
  }

  void clearError() {
    state = state.copyWith(clearError: true);
  }
}

final customerRepositoryProvider = Provider<CustomerRepository>((ref) {
  return CustomerRepository();
});

final customerControllerProvider =
    StateNotifierProvider.autoDispose<CustomerController, CustomerHomeState>((
      ref,
    ) {
      ref.watch(authControllerProvider.select((auth) => auth.userId));
      final repo = ref.watch(customerRepositoryProvider);
      final controller = CustomerController(repo);
      void localChanged() => unawaited(controller.restoreLocal());
      CustomerLocalStore.changes.addListener(localChanged);
      final timer = Timer.periodic(const Duration(minutes: 2), (_) {
        final lifecycle = WidgetsBinding.instance.lifecycleState;
        if (lifecycle == null || lifecycle == AppLifecycleState.resumed) {
          controller.refreshIfIdle();
        }
      });
      final connectivity = Connectivity().onConnectivityChanged.listen((
        results,
      ) {
        if (results.any((e) => e != ConnectivityResult.none)) {
          controller.refreshIfIdle();
        }
      });
      ref.onDispose(() {
        CustomerLocalStore.changes.removeListener(localChanged);
        timer.cancel();
        connectivity.cancel();
      });
      return controller;
    });
