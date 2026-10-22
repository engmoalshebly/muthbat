import 'dart:async';
import 'dart:convert';
import '../../../local_ledger/local_ledger_store.dart';
import '../../../auth/presentation/controllers/auth_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/finance/currency_info.dart';
import '../../../../core/sync/sync_engine.dart';
import '../../data/merchant_api_exception.dart';
import '../../data/merchant_repository.dart';
import '../../data/models/business_customer_model.dart';
import '../../data/models/dispute_model.dart';
import '../../data/models/ledger_entry_model.dart';

class MerchantDashboardState {
  final bool isLoading;
  final String businessId;
  final String businessName;
  final String businessCity;
  final String businessType;
  final String businessCountryCode;
  final String businessAddress;
  final String businessContactPhone;
  final String businessLogoPath;
  final Uint8List? businessLogoPreview;
  final String? businessLogoSyncStatus;
  final String businessTimezone;
  final String currency;
  final String
  currencyCode; // رمز عملة المحل الخام (YER/SAR/USD) — مرجع قفل منتقي العملة
  final List<String> supportedCurrencies;
  final List<CurrencyInfo> currencies;
  final List<BusinessCustomerModel> customers;
  final List<BusinessCustomerModel> dashboardCustomers;
  final bool hasMoreCustomers;
  final int totalCustomerCount;
  final List<LedgerEntryModel> recentEntries;
  final List<LedgerEntryModel> ledgerEntries;
  final double totalReceivables; // إجمالي ما للتاجر عند العملاء
  final double totalPayables; // إجمالي ما على التاجر للعملاء
  final Map<String, Map<String, double>>
  currencyBreakdown; // e.g. {'YER': {'receivables': 50000, 'payables': 0}}
  final String searchQuery;
  final List<DisputeModel> disputes;
  final int openDisputesCount;
  final bool isBusinessOwner;
  final String? lastErrorCode;
  final String? lastError; // آخر رسالة خطأ حقيقية — تُعرض للمستخدم بدل الصمت

  const MerchantDashboardState({
    this.isLoading = false,
    this.businessId = '',
    this.businessName = 'مؤسستي التجارية',
    this.businessCity = '',
    this.businessType = '',
    this.businessCountryCode = 'YE',
    this.businessAddress = '',
    this.businessContactPhone = '',
    this.businessLogoPath = '',
    this.businessLogoPreview,
    this.businessLogoSyncStatus,
    this.businessTimezone = 'Asia/Aden',
    this.currency = 'ر.ي',
    this.currencyCode = 'YER',
    this.supportedCurrencies = const ['YER'],
    this.currencies = CurrencyCatalog.defaults,
    this.customers = const [],
    this.dashboardCustomers = const [],
    this.hasMoreCustomers = false,
    this.totalCustomerCount = 0,
    this.recentEntries = const [],
    this.ledgerEntries = const [],
    this.totalReceivables = 0.0,
    this.totalPayables = 0.0,
    this.currencyBreakdown = const {},
    this.searchQuery = '',
    this.disputes = const [],
    this.openDisputesCount = 0,
    this.isBusinessOwner = false,
    this.lastError,
    this.lastErrorCode,
  });

  MerchantDashboardState copyWith({
    bool? isLoading,
    String? businessId,
    String? businessName,
    String? businessCity,
    String? businessType,
    String? businessCountryCode,
    String? businessAddress,
    String? businessContactPhone,
    String? businessLogoPath,
    Uint8List? businessLogoPreview,
    String? businessLogoSyncStatus,
    bool clearLogoPreview = false,
    String? businessTimezone,
    String? currency,
    String? currencyCode,
    List<String>? supportedCurrencies,
    List<CurrencyInfo>? currencies,
    List<BusinessCustomerModel>? customers,
    List<BusinessCustomerModel>? dashboardCustomers,
    bool? hasMoreCustomers,
    int? totalCustomerCount,
    List<LedgerEntryModel>? recentEntries,
    List<LedgerEntryModel>? ledgerEntries,
    double? totalReceivables,
    double? totalPayables,
    Map<String, Map<String, double>>? currencyBreakdown,
    String? searchQuery,
    List<DisputeModel>? disputes,
    int? openDisputesCount,
    bool? isBusinessOwner,
    String? lastError,
    String? lastErrorCode,
    bool clearError = false,
  }) {
    return MerchantDashboardState(
      isLoading: isLoading ?? this.isLoading,
      businessId: businessId ?? this.businessId,
      businessName: businessName ?? this.businessName,
      businessCity: businessCity ?? this.businessCity,
      businessType: businessType ?? this.businessType,
      businessCountryCode: businessCountryCode ?? this.businessCountryCode,
      businessAddress: businessAddress ?? this.businessAddress,
      businessContactPhone: businessContactPhone ?? this.businessContactPhone,
      businessLogoPath: businessLogoPath ?? this.businessLogoPath,
      businessLogoPreview: clearLogoPreview
          ? null
          : businessLogoPreview ?? this.businessLogoPreview,
      businessLogoSyncStatus: clearLogoPreview
          ? null
          : businessLogoSyncStatus ?? this.businessLogoSyncStatus,
      businessTimezone: businessTimezone ?? this.businessTimezone,
      currency: currency ?? this.currency,
      currencyCode: currencyCode ?? this.currencyCode,
      supportedCurrencies: supportedCurrencies ?? this.supportedCurrencies,
      currencies: currencies ?? this.currencies,
      customers: customers ?? this.customers,
      dashboardCustomers: dashboardCustomers ?? this.dashboardCustomers,
      hasMoreCustomers: hasMoreCustomers ?? this.hasMoreCustomers,
      totalCustomerCount: totalCustomerCount ?? this.totalCustomerCount,
      recentEntries: recentEntries ?? this.recentEntries,
      ledgerEntries: ledgerEntries ?? this.ledgerEntries,
      totalReceivables: totalReceivables ?? this.totalReceivables,
      totalPayables: totalPayables ?? this.totalPayables,
      currencyBreakdown: currencyBreakdown ?? this.currencyBreakdown,
      searchQuery: searchQuery ?? this.searchQuery,
      disputes: disputes ?? this.disputes,
      openDisputesCount: openDisputesCount ?? this.openDisputesCount,
      isBusinessOwner: isBusinessOwner ?? this.isBusinessOwner,
      lastError: clearError ? null : (lastError ?? this.lastError),
      lastErrorCode: clearError ? null : (lastErrorCode ?? this.lastErrorCode),
    );
  }
}

class MerchantController extends StateNotifier<MerchantDashboardState> {
  final MerchantRepository _repository;
  final void Function() _requestBackgroundSync;
  static void _syncInBackground() {
    unawaited(SyncEngine.instance.triggerSync());
  }

  int _dashboardGeneration = 0;
  String? _reportBusinessId;
  int _reportGeneration = 0;

  final String? _activeBusinessId;

  MerchantController(
    this._repository, {
    String? activeBusinessId,
    void Function()? requestSync,
  }) : _activeBusinessId = activeBusinessId,
       _requestBackgroundSync = requestSync ?? _syncInBackground,
       super(const MerchantDashboardState()) {
    loadDashboard();
  }

  @visibleForTesting
  MerchantController.forTesting(
    this._repository,
    MerchantDashboardState initialState,
  ) : _activeBusinessId = null,
      _requestBackgroundSync = _syncInBackground,
      super(initialState);

  /// ترجمة أخطاء PostgREST/الشبكة إلى رسائل عربية واضحة تُعرض للمستخدم
  String _friendlyError(Object e) {
    if (e is MerchantApiException) return e.message;
    final msg = e.toString();
    if (msg.contains('PGRST202')) {
      return 'عقد غير متطابق مع الخادم — حدّث التطبيق أو تواصل مع الدعم';
    }
    if (msg.contains('42501')) {
      return 'ليست لديك صلاحية لتنفيذ هذه العملية';
    }
    if (msg.contains('23514') ||
        msg.contains('Currencies with ledger entries')) {
      return 'لا يمكن تعطيل عملة مرتبطة بقيود مالية سابقة.';
    }
    if (msg.contains('42703')) {
      return 'البيانات غير متزامنة مع الخادم — أعد المزامنة ثم حاول';
    }
    if (msg.contains('SocketException') ||
        msg.contains('Failed host lookup') ||
        msg.contains('ClientException')) {
      return 'تعذر الاتصال بالخادم — تحقق من اتصالك بالإنترنت';
    }
    return msg.length > 180 ? '${msg.substring(0, 180)}…' : msg;
  }

  /// تحميل بيانات لوحة تحكم التاجر الفعلي من الكاش المحلي.
  ///
  /// هوية المستخدم من قاعدة الحساب المفتوحة محلياً؛ لا تنتظر تجديد جلسة الشبكة.
  Future<void> loadDashboard({String? userId, bool silent = false}) async {
    final dashboardGeneration = ++_dashboardGeneration;
    final directoryGeneration = ++_directoryGeneration;
    final directoryQuery = state.searchQuery;
    if (state.businessId.isEmpty) {
      state = state.copyWith(isLoading: true);
    }

    try {
      // مصدر الحقيقة الوحيد — جلسة Supabase الحية (لا cached_user_id)
      final currentUserId = userId ?? AppDatabase.instance.accountId;

      if (currentUserId == null || currentUserId.isEmpty) {
        state = state.copyWith(
          isLoading: false,
          lastError: 'لم يتم تسجيل الدخول. سجّل دخولك أولاً.',
        );
        return;
      }

      // البحث عن محل حقيقي مرتبط بالمستخدم (من المزامنة/الباكند)
      Map<String, dynamic>? activeBiz;
      final notebook = _activeBusinessId == null
          ? await LocalLedgerStore.instance.current()
          : null;
      String? preferredBusiness = _activeBusinessId;
      if (preferredBusiness != null) {
        preferredBusiness =
            await AppDatabase.instance.getServerId(preferredBusiness) ??
            preferredBusiness;
      }
      if (_activeBusinessId == null &&
          notebook != null &&
          notebook['transfer_state'] == 'complete' &&
          notebook['owner_id'] == currentUserId) {
        preferredBusiness = notebook['server_business_id'] as String?;
      }
      activeBiz = await AppDatabase.instance.getBusinessByOwnerId(
        currentUserId,
      );
      if (preferredBusiness != null && activeBiz?['id'] != preferredBusiness) {
        final db = await AppDatabase.instance.database;
        final matches = await db.query(
          'local_businesses',
          where: _activeBusinessId != null
              ? 'id = ?'
              : 'id = ? AND owner_user_id = ?',
          whereArgs: _activeBusinessId != null
              ? [preferredBusiness]
              : [preferredBusiness, currentUserId],
        );
        activeBiz = matches.isEmpty ? null : matches.first;
      }
      if (preferredBusiness == null) {
        activeBiz ??= await AppDatabase.instance.getActiveBusiness(
          currentUserId,
        );
      }

      // Only the synchronized account database is read while opening a screen.

      // لا يوجد محل حقيقي → حالة فارغة (المحل يُنشأ عبر create_business من الباكند)
      if (activeBiz == null) {
        if (!mounted || dashboardGeneration != _dashboardGeneration) return;
        state = state.copyWith(
          isLoading: false,
          businessId: '',
          businessName: '',
          businessLogoPath: '',
          clearLogoPreview: true,
          customers: const [],
          dashboardCustomers: const [],
          hasMoreCustomers: false,
          totalCustomerCount: 0,
          recentEntries: const [],
          ledgerEntries: const [],
          totalReceivables: 0.0,
          totalPayables: 0.0,
          clearError: true,
        );
        return;
      }

      final businessId = activeBiz['id'] as String;
      final isBusinessOwner = activeBiz['owner_user_id'] == currentUserId;
      final businessName = activeBiz['name'] as String? ?? '';
      final businessCity = activeBiz['city'] as String? ?? '';
      final businessType = activeBiz['business_type'] as String? ?? '';
      final businessCountryCode = activeBiz['country_code'] as String? ?? 'YE';
      final businessAddress = activeBiz['address'] as String? ?? '';
      final businessContactPhone =
          (activeBiz['contact_phone'] ?? activeBiz['contact_phone_display'])
              as String? ??
          '';
      final businessLogoPath = activeBiz['logo_path'] as String? ?? '';
      final database = await AppDatabase.instance.database;
      final logoQueue = await database.query(
        'offline_mutations_queue',
        columns: ['payload_json', 'status'],
        where: "local_ref_id=? AND command_type=? AND status!='dead_letter'",
        whereArgs: [businessId, 'upload_business_logo'],
        orderBy: 'id DESC',
        limit: 1,
      );
      Uint8List? logoPreview;
      String? logoStatus;
      if (logoQueue.isNotEmpty) {
        try {
          final payload =
              jsonDecode(logoQueue.first['payload_json'] as String)
                  as Map<String, dynamic>;
          final encoded = payload['bytes'];
          if (encoded is String) {
            logoPreview = base64Decode(encoded);
            logoStatus = logoQueue.first['status'] as String?;
          }
        } on FormatException {
          // An invalid cached preview must not prevent the dashboard from loading.
        }
      }
      final businessTimezone = activeBiz['timezone'] as String? ?? 'Asia/Aden';
      final currencyCode = (activeBiz['currency_code'] as String? ?? 'YER')
          .toUpperCase();
      final rawAdditional = activeBiz['additional_currencies'];
      final additionalCurrencies = rawAdditional is String
          ? (rawAdditional.isEmpty
                ? <String>[]
                : (jsonDecode(rawAdditional) as List)
                      .map((e) => e.toString().toUpperCase())
                      .toList())
          : rawAdditional is List
          ? rawAdditional.map((e) => e.toString().toUpperCase()).toList()
          : <String>[];
      final supportedCurrencies = <String>{
        currencyCode,
        ...additionalCurrencies,
      }.toList();
      final localCurrencies = await AppDatabase.instance.getCurrencies();
      final currencies = localCurrencies.isEmpty
          ? CurrencyCatalog.defaults
          : localCurrencies;

      final customers = await _repository.getCustomers(
        businessId,
        searchQuery: directoryQuery,
        limit: 51,
      );
      final dashboardCustomers = await _repository.getDashboardCustomers(
        businessId,
        currencyCode,
      );
      final ledgerEntryRows = await AppDatabase.instance
          .getRecentBusinessLedgerEntries(businessId, limit: 10);
      final ledgerEntries = ledgerEntryRows
          .map(LedgerEntryModel.fromMap)
          .toList();
      final recentEntries = ledgerEntries.take(10).toList();

      double receivables = 0.0;
      double payables = 0.0;
      final Map<String, Map<String, double>> breakdown = {
        for (final code in supportedCurrencies)
          code: {'receivables': 0.0, 'payables': 0.0, 'customers': 0.0},
      };

      final totals = await AppDatabase.instance.getActiveCustomerTotals(
        businessId,
        currencyCode,
      );
      for (final row in totals) {
        breakdown[row['currency_code'] as String] = {
          'receivables': (row['receivables'] as num).toDouble(),
          'payables': (row['payables'] as num).toDouble(),
          'customers': (row['customers'] as num).toDouble(),
        };
      }
      final totalCustomerCount = await AppDatabase.instance
          .countActiveCustomers(businessId);
      // Legacy headline totals are base-currency only; other currencies stay
      // isolated in currencyBreakdown.
      receivables = breakdown[currencyCode]?['receivables'] ?? 0.0;
      payables = breakdown[currencyCode]?['payables'] ?? 0.0;

      final disputes = await _repository.getCachedDisputes(businessId);
      final openDisputes = disputes.where((d) => d.isOpen).length;
      if (!mounted ||
          dashboardGeneration != _dashboardGeneration ||
          AppDatabase.instance.accountId != currentUserId) {
        return;
      }

      final nextState = state.copyWith(
        isLoading: false,
        businessId: businessId,
        businessName: businessName,
        businessCity: businessCity,
        businessType: businessType,
        businessCountryCode: businessCountryCode,
        businessAddress: businessAddress,
        businessContactPhone: businessContactPhone,
        businessLogoPath: businessLogoPath,
        businessLogoPreview: logoPreview,
        businessLogoSyncStatus: logoStatus,
        clearLogoPreview: logoPreview == null,
        businessTimezone: businessTimezone,
        currency: currencyCode == 'YER' ? 'ر.ي' : currencyCode,
        currencyCode: currencyCode,
        supportedCurrencies: supportedCurrencies,
        currencies: currencies,
        customers: directoryGeneration == _directoryGeneration
            ? customers.take(50).toList()
            : state.customers,
        hasMoreCustomers: directoryGeneration == _directoryGeneration
            ? customers.length > 50
            : state.hasMoreCustomers,
        totalCustomerCount: totalCustomerCount,
        dashboardCustomers: dashboardCustomers,
        recentEntries: recentEntries,
        ledgerEntries: _reportBusinessId == businessId
            ? state.ledgerEntries
            : ledgerEntries,
        totalReceivables: receivables,
        totalPayables: payables,
        currencyBreakdown: breakdown,
        disputes: disputes,
        openDisputesCount: openDisputes,
        isBusinessOwner: isBusinessOwner,
        clearError: !silent,
      );
      // A routine pull with no visible changes should not rebuild the entire
      // merchant dashboard or reset its current interaction.
      if (silent &&
          jsonEncode(_visibleDashboardSnapshot(state)) ==
              jsonEncode(_visibleDashboardSnapshot(nextState))) {
        return;
      }
      state = nextState;
    } catch (e) {
      if (!mounted || dashboardGeneration != _dashboardGeneration) return;
      state = state.copyWith(isLoading: false, lastError: _friendlyError(e));
    }
  }

  Map<String, Object?> _visibleDashboardSnapshot(MerchantDashboardState s) => {
    'businessId': s.businessId,
    'businessName': s.businessName,
    'businessCity': s.businessCity,
    'businessType': s.businessType,
    'businessCountryCode': s.businessCountryCode,
    'businessAddress': s.businessAddress,
    'businessContactPhone': s.businessContactPhone,
    'businessLogoPath': s.businessLogoPath,
    'businessTimezone': s.businessTimezone,
    'currencyCode': s.currencyCode,
    'supportedCurrencies': s.supportedCurrencies,
    'customers': s.customers.map((item) => item.toMap()).toList(),
    'dashboardCustomers': s.dashboardCustomers
        .map((item) => item.toMap())
        .toList(),
    'hasMoreCustomers': s.hasMoreCustomers,
    'totalCustomerCount': s.totalCustomerCount,
    'recentEntries': s.recentEntries.map((item) => item.toMap()).toList(),
    'totalReceivables': s.totalReceivables,
    'totalPayables': s.totalPayables,
    'currencyBreakdown': s.currencyBreakdown,
    'openDisputesCount': s.openDisputesCount,
    'lastError': s.lastError,
  };

  /// Load the year-long report only while its tab is open.
  Future<void> loadReportEntries() async {
    final generation = ++_reportGeneration;
    final businessId = state.businessId;
    final accountId = AppDatabase.instance.accountId;
    if (businessId.isEmpty || accountId == null) return;
    final rows = await AppDatabase.instance.getBusinessLedgerEntriesSince(
      businessId,
      DateTime.now().subtract(const Duration(days: 365)),
    );
    if (!mounted ||
        generation != _reportGeneration ||
        state.businessId != businessId ||
        AppDatabase.instance.accountId != accountId) {
      return;
    }
    _reportBusinessId = businessId;
    state = state.copyWith(
      ledgerEntries: rows.map(LedgerEntryModel.fromMap).toList(),
    );
  }

  bool get hasLocalReport => _reportBusinessId == state.businessId;

  void clearReportEntries() {
    _reportGeneration++;
    _reportBusinessId = null;
    state = state.copyWith(ledgerEntries: state.recentEntries);
  }

  Future<bool> updateCustomer({
    required String customerId,
    required String displayName,
    String? note,
    double? creditLimit,
    int? defaultDueDays,
  }) async {
    if (!state.isBusinessOwner) {
      state = state.copyWith(
        lastError: 'تعديل بيانات العميل متاح لمالك المتجر فقط',
      );
      return false;
    }
    try {
      await _repository.updateCustomer(
        customerId: customerId,
        displayName: displayName,
        note: note,
        creditLimit: creditLimit,
        defaultDueDays: defaultDueDays,
      );
      await loadDashboard();
      return true;
    } catch (e) {
      state = state.copyWith(lastError: _friendlyError(e));
      return false;
    }
  }

  Future<bool> archiveCustomer(String customerId) async {
    if (!state.isBusinessOwner) {
      state = state.copyWith(lastError: 'أرشفة العميل متاحة لمالك المتجر فقط');
      return false;
    }
    try {
      await _repository.archiveCustomer(customerId);
      await loadDashboard();
      return true;
    } catch (e) {
      state = state.copyWith(lastError: _friendlyError(e));
      return false;
    }
  }

  /// إنشاء منشأة تجارية جديدة للتاجر وتحديث لوحة التحكم
  Future<bool> createBusiness({
    required String name,
    required String businessType,
    required String currencyCode,
    List<String> additionalCurrencies = const [],
    String countryCode = 'YE',
    String? city,
    String? address,
    String? contactPhoneDisplay,
    Uint8List? logoBytes,
    String logoExtension = 'jpg',
  }) async {
    state = state.copyWith(
      isLoading: state.businessId.isEmpty,
      clearError: true,
    );
    try {
      await _repository.createBusiness(
        name: name,
        businessType: businessType,
        currencyCode: currencyCode,
        additionalCurrencies: additionalCurrencies,
        countryCode: countryCode,
        city: city,
        address: address,
        contactPhoneDisplay: contactPhoneDisplay,
        logoBytes: logoBytes,
        logoExtension: logoExtension,
      );
      await loadDashboard();
      return true;
    } catch (e) {
      state = state.copyWith(isLoading: false, lastError: _friendlyError(e));
      return false;
    }
  }

  Future<bool> updateCurrencies(List<String> additionalCurrencies) async {
    if (state.businessId.isEmpty) return false;
    state = state.copyWith(clearError: true);
    try {
      await _repository.updateBusinessCurrencies(
        businessId: state.businessId,
        additionalCurrencies: additionalCurrencies,
      );
      await loadDashboard();
      return true;
    } catch (e) {
      state = state.copyWith(isLoading: false, lastError: _friendlyError(e));
      return false;
    }
  }

  Future<bool> updateBusinessLogo({
    required Uint8List bytes,
    required String extension,
  }) async {
    if (state.businessId.isEmpty) return false;
    state = state.copyWith(clearError: true);
    try {
      await _repository.updateBusinessLogo(
        businessId: state.businessId,
        bytes: bytes,
        extension: extension,
      );
      await loadDashboard();
      return true;
    } catch (e) {
      state = state.copyWith(isLoading: false, lastError: _friendlyError(e));
      return false;
    }
  }

  Future<bool> updateBusinessProfile({
    required String name,
    required String businessType,
    required String countryCode,
    required String city,
    required String address,
    required String contactPhone,
    required String timezone,
  }) async {
    if (state.businessId.isEmpty) return false;
    state = state.copyWith(clearError: true);
    try {
      await _repository.updateBusinessProfile(
        businessId: state.businessId,
        name: name,
        businessType: businessType,
        countryCode: countryCode,
        city: city,
        address: address,
        contactPhone: contactPhone,
        timezone: timezone,
      );
      await loadDashboard();
      return true;
    } catch (e) {
      state = state.copyWith(isLoading: false, lastError: _friendlyError(e));
      return false;
    }
  }

  /// إعادة تحميل قائمة الاعتراضات
  Future<void> loadDisputes() async {
    if (state.businessId.isEmpty) return;
    try {
      final disputes = await _repository.getDisputes(state.businessId);
      final openDisputes = disputes.where((d) => d.isOpen).length;
      state = state.copyWith(
        disputes: disputes,
        openDisputesCount: openDisputes,
      );
    } catch (e) {
      debugPrint('loadDisputes error: $e');
      state = state.copyWith(lastError: _friendlyError(e));
    }
  }

  /// إرسال رسالة في الاعتراض
  Future<bool> sendDisputeMessage(String disputeId, String message) async {
    try {
      final success = await _repository.addDisputeMessage(disputeId, message);
      if (success) {
        await loadDisputes();
      }
      return success;
    } catch (error) {
      if (mounted) state = state.copyWith(lastError: _friendlyError(error));
      return false;
    }
  }

  /// حل الاعتراض
  Future<bool> resolveDispute({
    required String disputeId,
    required String resolution,
    required String note,
    double? correctedAmount,
  }) async {
    try {
      final success = await _repository.resolveDispute(
        disputeId: disputeId,
        resolution: resolution,
        note: note,
        correctedAmount: correctedAmount,
      );
      if (success) {
        await loadDashboard();
      }
      return success;
    } catch (error) {
      if (mounted) state = state.copyWith(lastError: _friendlyError(error));
      return false;
    }
  }

  /// تصفية وبحث في قائمة العملاء
  int _directoryGeneration = 0;
  bool _loadingMore = false;
  Future<void> search(String query) async {
    final generation = ++_directoryGeneration;
    final business = state.businessId;
    state = state.copyWith(searchQuery: query);
    try {
      final page = await _repository.getCustomers(
        business,
        searchQuery: query,
        limit: 51,
      );
      if (!mounted ||
          generation != _directoryGeneration ||
          state.businessId != business) {
        return;
      }
      state = state.copyWith(
        customers: page.take(50).toList(),
        hasMoreCustomers: page.length > 50,
      );
    } catch (e) {
      if (mounted && generation == _directoryGeneration) {
        state = state.copyWith(lastError: _friendlyError(e));
      }
    }
  }

  Future<void> loadMoreCustomers() async {
    if (_loadingMore || !state.hasMoreCustomers) return;
    _loadingMore = true;
    final generation = _directoryGeneration,
        business = state.businessId,
        query = state.searchQuery;
    try {
      final page = await _repository.getCustomers(
        business,
        searchQuery: query,
        limit: 51,
        offset: state.customers.length,
      );
      if (!mounted ||
          generation != _directoryGeneration ||
          business != state.businessId ||
          query != state.searchQuery) {
        return;
      }
      final combined = {
        for (final c in [...state.customers, ...page.take(50)]) c.id: c,
      };
      state = state.copyWith(
        customers: combined.values.toList(),
        hasMoreCustomers: page.length > 50,
      );
    } catch (e) {
      if (mounted && generation == _directoryGeneration) {
        state = state.copyWith(lastError: _friendlyError(e));
      }
    } finally {
      _loadingMore = false;
    }
  }

  /// إضافة عميل جديد
  Future<BusinessCustomerModel?> addCustomer({
    required String name,
    String? phone,
    String? note,
    double? creditLimit,
    int? dueDays,
  }) async {
    try {
      var bizId = state.businessId;
      if (bizId.isEmpty) {
        final currentUserId = AppDatabase.instance.accountId;
        if (currentUserId != null) {
          final biz =
              await AppDatabase.instance.getBusinessByOwnerId(currentUserId) ??
              await AppDatabase.instance.getActiveBusiness(currentUserId);
          if (biz != null) {
            bizId = biz['id'] as String;
          }
        }
      }
      if (bizId.isEmpty) {
        throw const MerchantApiException(
          code: 'no_business',
          message: 'لم يتم العثور على منشأة تجارية نشطة.',
        );
      }

      final customer = await _repository.addCustomer(
        businessId: bizId,
        localDisplayName: name,
        phone: phone,
        localNote: note,
        creditLimit: creditLimit,
        defaultDueDays: dueDays,
      );
      await loadDashboard();
      return customer;
    } catch (e) {
      debugPrint('[MerchantController] addCustomer error: $e');
      final apiError = MerchantApiException.from(e);
      state = state.copyWith(
        lastError: apiError.message,
        lastErrorCode: apiError.code,
      );
      return null;
    }
  }

  /// إضافة دين أو دفعة سريعة للعميل مع تحديد العملة وتصنيف العملية وطريقة السداد
  Future<bool> createEntry({
    required String businessCustomerId,
    required String entryType,
    required double amount,
    required String description,
    required String currencyCode,
    String category = 'goods',
    String paymentMethod = 'cash',
    String? referenceNumber,
    String? bankOrAgentName,
    String? attachmentPath,
    String? dueDate,
  }) async {
    try {
      await _repository.createLedgerEntry(
        businessId: state.businessId,
        businessCustomerId: businessCustomerId,
        entryType: entryType,
        amount: amount,
        description: description,
        currencyCode: currencyCode,
        category: category,
        paymentMethod: paymentMethod,
        referenceNumber: referenceNumber,
        bankOrAgentName: bankOrAgentName,
        attachmentPath: attachmentPath,
        dueDate: dueDate,
      );
      await loadDashboard();
      return true;
    } catch (e) {
      state = state.copyWith(lastError: _friendlyError(e));
      return false;
    }
  }

  /// تطبيق خصم للعميل
  Future<bool> applyDiscount({
    required String businessCustomerId,
    required double amount,
    required String description,
    required String currencyCode,
  }) async {
    try {
      await _repository.applyCustomerDiscount(
        businessId: state.businessId,
        businessCustomerId: businessCustomerId,
        amount: amount,
        description: description,
        currencyCode: currencyCode,
      );
      await loadDashboard();
      return true;
    } catch (e) {
      state = state.copyWith(lastError: _friendlyError(e));
      return false;
    }
  }

  /// عكس قيد مالي (إلغاء عملية سابقة)
  Future<bool> reverseEntry({
    required String originalEntryId,
    required String businessCustomerId,
    required String originalEntryType,
    required String originalDirection,
    required double originalAmount,
    required String reason,
    required String currencyCode,
  }) async {
    try {
      await _repository.reverseLedgerEntry(
        businessId: state.businessId,
        originalEntryId: originalEntryId,
        businessCustomerId: businessCustomerId,
        originalEntryType: originalEntryType,
        originalDirection: originalDirection,
        originalAmount: originalAmount,
        reason: reason,
        currencyCode: currencyCode,
      );
      await loadDashboard();
      return true;
    } catch (e) {
      state = state.copyWith(lastError: _friendlyError(e));
      return false;
    }
  }

  /// تشغيل المزامنة الفورية
  Future<bool> syncNow() async {
    _requestBackgroundSync();
    await loadDashboard(silent: true);
    return true; // Local refresh completed; cloud outcome is reported separately.
  }
}

final merchantRepositoryProvider = Provider<MerchantRepository>((ref) {
  return MerchantRepository();
});

final merchantControllerProvider =
    StateNotifierProvider<MerchantController, MerchantDashboardState>((ref) {
      ref.watch(authControllerProvider.select((auth) => auth.userId));
      final activeBusinessId = ref.watch(
        authControllerProvider.select((auth) => auth.activeBusinessId),
      );
      ref.watch(authControllerProvider.select((auth) => auth.businessRole));
      final repo = ref.watch(merchantRepositoryProvider);
      return MerchantController(repo, activeBusinessId: activeBusinessId);
    });
