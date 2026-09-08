import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../../data/customer_repository.dart';
import '../../data/customer_cache.dart';
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
    String? errorMessage,
    bool clearError = false,
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
      customerId: customerId ?? this.customerId,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      summaries: summaries ?? this.summaries,
      linkRequests: linkRequests ?? this.linkRequests,
      pendingEntries: pendingEntries ?? this.pendingEntries,
    );
  }
}

class CustomerController extends StateNotifier<CustomerHomeState> {
  int _loadVersion = 0;
  final _cache = CustomerCache();
  final CustomerRepository _repository;

  CustomerController(this._repository) : super(const CustomerHomeState());

  void refreshIfIdle({bool onlyPending = false}) {
    if (!mounted || state.isLoading) return;
    if (onlyPending && !state.outbox.any((e) => e['status'] == 'pending')) {
      return;
    }
    unawaited(load());
  }

  /// تحميل كل بيانات الشاشة من الخادم (الملخص + طلبات الربط + القيود المعلقة)
  Future<void> load() async {
    final version = ++_loadVersion;
    final owner = _repository.userId;
    if (owner == null) {
      state = const CustomerHomeState(hasCustomerAccount: false);
      return;
    }
    bool current() =>
        mounted && version == _loadVersion && _repository.userId == owner;
    state = state.copyWith(isLoading: true, clearError: true);

    try {
      try {
        final saved = await _cache.read(owner, 'home');
        if (!current()) return;
        if (saved != null) {
          state = CustomerHomeState(
            isLoading: true,
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
      await _repository.flushOutbox();
      final remaining = await _repository.pendingActions();
      if (!current()) return;
      state = state.copyWith(outbox: remaining);
      final customerId = await _repository.resolveCustomerId();
      if (!current()) return;
      if (customerId == null) {
        state = CustomerHomeState(
          outbox: state.outbox,
          isLoading: false,
          hasCustomerAccount: false,
          customerId: null,
          summaries: [],
          linkRequests: [],
          pendingEntries: [],
        );
        try {
          await _cache.write(owner, 'home', {
            'customer_id': null,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
            'summaries': [],
            'requests': [],
            'entries': [],
          });
        } catch (_) {
          /* Do not turn a successful empty response into an error. */
        }
        return;
      }

      final results = await Future.wait([
        _repository.fetchBusinessSummaries(customerId),
        _repository.fetchPendingLinkRequests(customerId),
        _repository.fetchPendingEntries(customerId),
      ]);
      if (!current()) return;

      state = state.copyWith(
        isCached: false,
        updatedAt: DateTime.now().toUtc().toIso8601String(),
        isLoading: false,
        hasCustomerAccount: true,
        customerId: customerId,
        summaries: results[0] as List<CustomerBusinessSummary>,
        linkRequests: results[1] as List<CustomerLinkRequestModel>,
        pendingEntries: results[2] as List<CustomerPendingEntry>,
      );
      try {
        await _cache.write(owner, 'home', {
          'customer_id': customerId,
          'updated_at': state.updatedAt,
          'summaries': state.summaries.map((e) => e.toMap()).toList(),
          'requests': state.linkRequests.map((e) => e.toMap()).toList(),
          'entries': state.pendingEntries.map((e) => e.toMap()).toList(),
        });
      } catch (_) {
        /* Online data remains usable when local storage is unavailable. */
      }
    } catch (e) {
      if (!current()) return;
      state = state.copyWith(
        isLoading: false,
        isCached: state.updatedAt != null,
        errorMessage: e.toString().replaceFirst('Exception: ', ''),
      );
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
      await load();
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
      await load();
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
      await load();
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
    StateNotifierProvider<CustomerController, CustomerHomeState>((ref) {
      ref.watch(authControllerProvider.select((auth) => auth.userId));
      final repo = ref.watch(customerRepositoryProvider);
      final controller = CustomerController(repo);
      final timer = Timer.periodic(const Duration(seconds: 30), (_) {
        controller.refreshIfIdle(onlyPending: true);
      });
      final connectivity = Connectivity().onConnectivityChanged.listen((
        results,
      ) {
        if (results.any((e) => e != ConnectivityResult.none)) {
          controller.refreshIfIdle();
        }
      });
      ref.onDispose(() {
        timer.cancel();
        connectivity.cancel();
      });
      return controller;
    });
