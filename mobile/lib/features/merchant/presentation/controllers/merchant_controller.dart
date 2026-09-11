import 'dart:convert';
import '../../../local_ledger/local_ledger_store.dart';
import '../../../auth/presentation/controllers/auth_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
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
  final String businessTimezone;
  final String currency;
  final String
  currencyCode; // رمز عملة المحل الخام (YER/SAR/USD) — مرجع قفل منتقي العملة
  final List<String> supportedCurrencies;
  final List<CurrencyInfo> currencies;
  final List<BusinessCustomerModel> customers;
  final List<LedgerEntryModel> recentEntries;
  final List<LedgerEntryModel> ledgerEntries;
  final double totalReceivables; // إجمالي ما للتاجر عند العملاء
  final double totalPayables; // إجمالي ما على التاجر للعملاء
  final Map<String, Map<String, double>>
  currencyBreakdown; // e.g. {'YER': {'receivables': 50000, 'payables': 0}}
  final String searchQuery;
  final List<DisputeModel> disputes;
  final int openDisputesCount;
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
    this.businessTimezone = 'Asia/Aden',
    this.currency = 'ر.ي',
    this.currencyCode = 'YER',
    this.supportedCurrencies = const ['YER'],
    this.currencies = CurrencyCatalog.defaults,
    this.customers = const [],
    this.recentEntries = const [],
    this.ledgerEntries = const [],
    this.totalReceivables = 0.0,
    this.totalPayables = 0.0,
    this.currencyBreakdown = const {},
    this.searchQuery = '',
    this.disputes = const [],
    this.openDisputesCount = 0,
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
    String? businessTimezone,
    String? currency,
    String? currencyCode,
    List<String>? supportedCurrencies,
    List<CurrencyInfo>? currencies,
    List<BusinessCustomerModel>? customers,
    List<LedgerEntryModel>? recentEntries,
    List<LedgerEntryModel>? ledgerEntries,
    double? totalReceivables,
    double? totalPayables,
    Map<String, Map<String, double>>? currencyBreakdown,
    String? searchQuery,
    List<DisputeModel>? disputes,
    int? openDisputesCount,
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
      businessTimezone: businessTimezone ?? this.businessTimezone,
      currency: currency ?? this.currency,
      currencyCode: currencyCode ?? this.currencyCode,
      supportedCurrencies: supportedCurrencies ?? this.supportedCurrencies,
      currencies: currencies ?? this.currencies,
      customers: customers ?? this.customers,
      recentEntries: recentEntries ?? this.recentEntries,
      ledgerEntries: ledgerEntries ?? this.ledgerEntries,
      totalReceivables: totalReceivables ?? this.totalReceivables,
      totalPayables: totalPayables ?? this.totalPayables,
      currencyBreakdown: currencyBreakdown ?? this.currencyBreakdown,
      searchQuery: searchQuery ?? this.searchQuery,
      disputes: disputes ?? this.disputes,
      openDisputesCount: openDisputesCount ?? this.openDisputesCount,
      lastError: clearError ? null : (lastError ?? this.lastError),
      lastErrorCode: clearError ? null : (lastErrorCode ?? this.lastErrorCode),
    );
  }
}

class MerchantController extends StateNotifier<MerchantDashboardState> {
  final MerchantRepository _repository;

  MerchantController(this._repository) : super(const MerchantDashboardState()) {
    loadDashboard();
  }

  /// ترجمة أخطاء PostgREST/الشبكة إلى رسائل عربية واضحة تُعرض للمستخدم
  String _friendlyError(Object e) {
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
  /// مصدر الحقيقة الوحيد للمستخدم هو جلسة Supabase Auth — لا SharedPreferences.
  /// إذا لم يوجد محل حقيقي (بيانات من السيرفر عبر المزامنة)، تظهر حالة فارغة
  /// بدل فبركة محل وهمي (كان biz-$userId — أُلغي لأنه هوية مفبركة).
  Future<void> loadDashboard([String? userId]) async {
    state = state.copyWith(isLoading: true);

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
      final notebook = await LocalLedgerStore.instance.current();
      String? preferredBusiness;
      if (notebook != null &&
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
          where: 'id = ? AND owner_user_id = ?',
          whereArgs: [preferredBusiness, currentUserId],
        );
        activeBiz = matches.isEmpty ? null : matches.first;
      }
      if (preferredBusiness == null)
        activeBiz ??= await AppDatabase.instance.getActiveBusiness(
          currentUserId,
        );

      // إذا لم يوجد في الكاش المحلي، نقوم بجلبه من Supabase مباشرة
      if (activeBiz == null) {
        try {
          var businessQuery = Supabase.instance.client
              .from('businesses')
              .select()
              .eq('owner_user_id', currentUserId);
          if (preferredBusiness != null)
            businessQuery = businessQuery.eq('id', preferredBusiness);
          final serverBiz = await businessQuery.limit(1).maybeSingle();
          if (serverBiz != null) {
            final localServerBiz = Map<String, dynamic>.from(serverBiz);
            final rawCurrencies = localServerBiz['additional_currencies'];
            localServerBiz['additional_currencies'] = jsonEncode(
              rawCurrencies is List
                  ? rawCurrencies
                        .map((e) => e.toString().toUpperCase())
                        .toList()
                  : const [],
            );
            await AppDatabase.instance.saveBusiness({
              'id': localServerBiz['id'],
              'owner_user_id': localServerBiz['owner_user_id'],
              'name': localServerBiz['name'],
              'business_type': localServerBiz['business_type'],
              'currency_code': localServerBiz['currency_code'],
              'additional_currencies': localServerBiz['additional_currencies'],
              'country_code': localServerBiz['country_code'],
              'city': localServerBiz['city'],
              'address': localServerBiz['address'],
              'contact_phone': localServerBiz['contact_phone_display'],
              'logo_path': localServerBiz['logo_path'],
              'timezone': localServerBiz['timezone'],
              'is_active': 1,
              'created_at': localServerBiz['created_at'],
            });
            activeBiz = serverBiz;
          }
        } catch (e) {
          debugPrint('[MerchantController] fetch business error: $e');
        }
      }

      // لا يوجد محل حقيقي → حالة فارغة (المحل يُنشأ عبر create_business من الباكند)
      if (activeBiz == null) {
        state = state.copyWith(
          isLoading: false,
          businessId: '',
          businessName: '',
          customers: const [],
          recentEntries: const [],
          ledgerEntries: const [],
          totalReceivables: 0.0,
          totalPayables: 0.0,
          clearError: true,
        );
        return;
      }

      final businessId = activeBiz['id'] as String;
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
        searchQuery: state.searchQuery,
      );
      final ledgerEntryRows = await AppDatabase.instance
          .getRecentBusinessLedgerEntries(businessId, limit: 10000);
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

      for (final c in customers) {
        if (c.currencyBalances.isNotEmpty) {
          c.currencyBalances.forEach((curr, bal) {
            final key = curr.toUpperCase();
            breakdown.putIfAbsent(
              key,
              () => {'receivables': 0.0, 'payables': 0.0, 'customers': 0.0},
            );
            if (bal > 0) {
              breakdown[key]!['receivables'] =
                  (breakdown[key]!['receivables'] ?? 0.0) + bal;
              breakdown[key]!['customers'] =
                  (breakdown[key]!['customers'] ?? 0.0) + 1;
            } else if (bal < 0) {
              breakdown[key]!['payables'] =
                  (breakdown[key]!['payables'] ?? 0.0) + bal.abs();
              breakdown[key]!['customers'] =
                  (breakdown[key]!['customers'] ?? 0.0) + 1;
            }
          });
        } else if (c.currentBalance != 0) {
          // Legacy balance assigned to YER
          if (c.currentBalance > 0) {
            breakdown.putIfAbsent(
              currencyCode,
              () => {'receivables': 0.0, 'payables': 0.0, 'customers': 0.0},
            );
            breakdown[currencyCode]!['receivables'] =
                (breakdown[currencyCode]!['receivables'] ?? 0.0) +
                c.currentBalance;
            breakdown[currencyCode]!['customers'] =
                (breakdown[currencyCode]!['customers'] ?? 0.0) + 1;
          } else if (c.currentBalance < 0) {
            breakdown.putIfAbsent(
              currencyCode,
              () => {'receivables': 0.0, 'payables': 0.0, 'customers': 0.0},
            );
            breakdown[currencyCode]!['payables'] =
                (breakdown[currencyCode]!['payables'] ?? 0.0) +
                c.currentBalance.abs();
            breakdown[currencyCode]!['customers'] =
                (breakdown[currencyCode]!['customers'] ?? 0.0) + 1;
          }
        }
      }
      // Legacy headline totals are base-currency only; other currencies stay
      // isolated in currencyBreakdown.
      receivables = breakdown[currencyCode]?['receivables'] ?? 0.0;
      payables = breakdown[currencyCode]?['payables'] ?? 0.0;

      final disputes = await _repository.getDisputes(businessId);
      final openDisputes = disputes.where((d) => d.isOpen).length;

      state = state.copyWith(
        isLoading: false,
        businessId: businessId,
        businessName: businessName,
        businessCity: businessCity,
        businessType: businessType,
        businessCountryCode: businessCountryCode,
        businessAddress: businessAddress,
        businessContactPhone: businessContactPhone,
        businessLogoPath: businessLogoPath,
        businessTimezone: businessTimezone,
        currency: currencyCode == 'YER' ? 'ر.ي' : currencyCode,
        currencyCode: currencyCode,
        supportedCurrencies: supportedCurrencies,
        currencies: currencies,
        customers: customers,
        recentEntries: recentEntries,
        ledgerEntries: ledgerEntries,
        totalReceivables: receivables,
        totalPayables: payables,
        currencyBreakdown: breakdown,
        disputes: disputes,
        openDisputesCount: openDisputes,
        clearError: true,
      );
    } catch (e) {
      state = state.copyWith(isLoading: false, lastError: _friendlyError(e));
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
    state = state.copyWith(isLoading: true, clearError: true);
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
    state = state.copyWith(isLoading: true, clearError: true);
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
    state = state.copyWith(isLoading: true, clearError: true);
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
    state = state.copyWith(isLoading: true, clearError: true);
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
    final success = await _repository.addDisputeMessage(disputeId, message);
    if (success) {
      await loadDisputes();
    }
    return success;
  }

  /// حل الاعتراض
  Future<bool> resolveDispute({
    required String disputeId,
    required String resolution,
    required String note,
    double? correctedAmount,
  }) async {
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
  }

  /// تصفية وبحث في قائمة العملاء
  void search(String query) {
    state = state.copyWith(searchQuery: query);
    loadDashboard();
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
        final currentUserId = Supabase.instance.client.auth.currentUser?.id;
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
    String currencyCode = 'YER',
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
    String currencyCode = 'YER',
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
    String currencyCode = 'YER',
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
  Future<void> syncNow() async {
    await SyncEngine.instance.triggerSync();
    await loadDashboard();
  }
}

final merchantRepositoryProvider = Provider<MerchantRepository>((ref) {
  return MerchantRepository();
});

final merchantControllerProvider =
    StateNotifierProvider<MerchantController, MerchantDashboardState>((ref) {
      ref.watch(authControllerProvider.select((auth) => auth.userId));
      final repo = ref.watch(merchantRepositoryProvider);
      return MerchantController(repo);
    });
