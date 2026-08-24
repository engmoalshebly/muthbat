import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/customer_repository.dart';
import '../../data/models/customer_summary_model.dart';

/// حالة شاشة العميل الرئيسية — بيانات حقيقية من الخادم فقط، بلا أي نصوص ثابتة.
class CustomerHomeState {
  final bool isLoading;
  final bool hasCustomerAccount; // false = لا سجل customers مرتبط بالمستخدم
  final String? customerId;
  final String? errorMessage; // خطأ التحميل العام (يُعرض مع زر إعادة المحاولة)
  final List<CustomerBusinessSummary> summaries;
  final List<CustomerLinkRequestModel> linkRequests;
  final List<CustomerPendingEntry> pendingEntries;

  const CustomerHomeState({
    this.isLoading = false,
    this.hasCustomerAccount = true,
    this.customerId,
    this.errorMessage,
    this.summaries = const [],
    this.linkRequests = const [],
    this.pendingEntries = const [],
  });

  CustomerHomeState copyWith({
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
  final CustomerRepository _repository;

  CustomerController(this._repository) : super(const CustomerHomeState());

  /// تحميل كل بيانات الشاشة من الخادم (الملخص + طلبات الربط + القيود المعلقة)
  Future<void> load() async {
    state = state.copyWith(isLoading: true, clearError: true);

    try {
      final customerId = await _repository.resolveCustomerId();
      if (customerId == null) {
        state = state.copyWith(
          isLoading: false,
          hasCustomerAccount: false,
          customerId: null,
          summaries: const [],
          linkRequests: const [],
          pendingEntries: const [],
        );
        return;
      }

      final results = await Future.wait([
        _repository.fetchBusinessSummaries(customerId),
        _repository.fetchPendingLinkRequests(customerId),
        _repository.fetchPendingEntries(customerId),
      ]);

      state = state.copyWith(
        isLoading: false,
        hasCustomerAccount: true,
        customerId: customerId,
        summaries: results[0] as List<CustomerBusinessSummary>,
        linkRequests: results[1] as List<CustomerLinkRequestModel>,
        pendingEntries: results[2] as List<CustomerPendingEntry>,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: e.toString().replaceFirst('Exception: ', ''),
      );
    }
  }

  /// الرد على طلب ربط — يعيد true عند النجاح، ويرمي رسالة الخطأ للواجهة عند الفشل
  Future<bool> respondToLinkRequest(String requestId, bool accept) async {
    try {
      await _repository.respondLinkRequest(
        requestId: requestId,
        accept: accept,
      );
      await load();
      return true;
    } catch (e) {
      state = state.copyWith(
        errorMessage: e.toString().replaceFirst('Exception: ', ''),
      );
      return false;
    }
  }

  /// تأكيد قيد مالي معلق — يحدّث القوائم بعد النجاح
  Future<bool> confirmEntry(String entryId) async {
    try {
      await _repository.confirmEntry(entryId);
      // إزالة القيد محلياً فوراً ثم إعادة التحميل من الخادم (مصدر الحقيقة)
      state = state.copyWith(
        pendingEntries: state.pendingEntries
            .where((e) => e.id != entryId)
            .toList(),
      );
      await load();
      return true;
    } catch (e) {
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
    try {
      await _repository.openDispute(
        entryId: entryId,
        reason: reason,
        description: description,
      );
      state = state.copyWith(
        pendingEntries: state.pendingEntries
            .where((entry) => entry.id != entryId)
            .toList(),
      );
      await load();
      return true;
    } catch (e) {
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
      final repo = ref.watch(customerRepositoryProvider);
      return CustomerController(repo);
    });
