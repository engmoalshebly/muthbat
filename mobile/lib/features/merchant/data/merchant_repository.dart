import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'package:sqflite_sqlcipher/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../../../core/finance/money.dart';
import '../../../core/finance/currency_info.dart';
import '../../../core/validation/customer_phone.dart';
import '../../../core/sync/sync_engine.dart';
import 'merchant_api_exception.dart';
import 'business_logo.dart';
import 'local_statement_totals.dart';
import 'models/business_customer_model.dart';
import 'models/dispute_message_model.dart';
import 'models/dispute_model.dart';
import 'models/ledger_entry_model.dart';
import 'models/statement_model.dart';
import 'rpc_contract.dart';

/// مستودع بيانات التاجر.
///
/// كل أسماء RPC وحمولاتها تمر عبر [RpcContract] المركزي (خطة 02 خطوة 4)،
/// وكل الأخطاء تُرمى كـ [MerchantApiException] غنية — ممنوع `return false/null`
/// الصامت (خطة 06 خطوة 3.9).
class MerchantRepository {
  MerchantRepository({void Function()? requestSync})
    : _requestSync = requestSync ?? _startSync;
  final void Function() _requestSync;
  static Timer? _syncDebounce;
  static void _startSync() {
    final owner = AppDatabase.instance.accountId;
    _syncDebounce?.cancel();
    _syncDebounce = Timer(const Duration(milliseconds: 350), () {
      if (owner != null && AppDatabase.instance.accountId == owner) {
        unawaited(SyncEngine.instance.triggerSync());
      }
    });
  }

  final _uuid = const Uuid();

  static final RegExp _uuidRegex = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  /// قراءة قائمة العملاء من الكاش المحلي مع إرفاق أرصدة العملات المتعددة
  Future<List<BusinessCustomerModel>> getCustomers(
    String businessId, {
    String? searchQuery,
    int? limit,
    int offset = 0,
  }) async {
    final rows = await AppDatabase.instance.getBusinessCustomers(
      businessId,
      searchQuery: searchQuery,
      limit: limit,
      offset: offset,
    );
    final List<BusinessCustomerModel> result = [];

    if (rows.isEmpty) return [];
    final allBalances = await AppDatabase.instance.getBusinessCurrencyBalances(
      businessId,
      customerIds: limit == null
          ? null
          : rows.map((r) => r['id'] as String).toList(),
    );
    for (final row in rows) {
      final custId = row['id'] as String;
      final currencyBals = allBalances[custId] ?? <String, double>{};
      result.add(BusinessCustomerModel.fromMap(row, currencyBals));
    }
    return result;
  }

  Future<List<BusinessCustomerModel>> getDashboardCustomers(
    String businessId,
    String baseCurrency,
  ) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.rawQuery(
      '''WITH amounts AS (
      SELECT b.business_customer_id id,b.currency_code,b.current_balance_minor minor
      FROM local_customer_currency_balances b JOIN local_business_customers c ON c.id=b.business_customer_id
      WHERE c.business_id=? AND c.is_archived=0
      UNION ALL SELECT c.id,?,c.current_balance_minor FROM local_business_customers c
      WHERE c.business_id=? AND c.is_archived=0 AND NOT EXISTS(SELECT 1 FROM local_customer_currency_balances b WHERE b.business_customer_id=c.id)
    ), ranked AS (SELECT id,minor,ROW_NUMBER() OVER(PARTITION BY currency_code ORDER BY minor DESC,id) position FROM amounts),
    wanted AS (SELECT id FROM ranked WHERE position<=10 AND minor>0
      UNION SELECT business_customer_id FROM (SELECT business_customer_id FROM local_ledger_entries WHERE business_id=? ORDER BY occurred_at DESC,created_at DESC LIMIT 10)
      UNION SELECT id FROM (SELECT id FROM local_business_customers WHERE business_id=? AND is_archived=0 ORDER BY updated_at DESC,id LIMIT 4))
    SELECT c.* FROM local_business_customers c WHERE c.business_id=? AND c.id IN (SELECT id FROM wanted)
    ORDER BY c.updated_at DESC,c.id''',
      [
        businessId,
        baseCurrency,
        businessId,
        businessId,
        businessId,
        businessId,
      ],
    );
    if (rows.isEmpty) return [];
    final balances = await AppDatabase.instance.getBusinessCurrencyBalances(
      businessId,
      customerIds: rows.map((r) => r['id'] as String).toList(),
    );
    return rows
        .map((r) => BusinessCustomerModel.fromMap(r, balances[r['id']] ?? {}))
        .toList();
  }

  /// إنشاء منشأة تجارية جديدة للمستخدم
  /// أونلاين: استدعاء RPC create_business وحفظ النتيجة محلياً.
  /// أوفلاين: حفظ المنشأة محلياً بمعرف مؤقت وإدراج أمر create_business في طابور المزامنة.
  Future<Map<String, dynamic>> createBusiness({
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
    final store = AppDatabase.instance;
    final owner = store.accountId;
    if (owner == null) {
      throw const MerchantApiException(
        code: 'unauthenticated',
        message: 'سجّل الدخول لإنشاء النشاط',
      );
    }
    if (name.trim().length < 2 ||
        name.trim().length > 120 ||
        businessType.trim().length < 2 ||
        businessType.trim().length > 120 ||
        (city?.trim().length ?? 0) > 120 ||
        (address?.trim().length ?? 0) > 500 ||
        !RegExp(r'^[A-Z]{2}$').hasMatch(countryCode.toUpperCase()) ||
        !CurrencyCatalog.allowedCodes.contains(currencyCode.toUpperCase()) ||
        additionalCurrencies.any(
          (code) => !CurrencyCatalog.allowedCodes.contains(code.toUpperCase()),
        )) {
      throw const FormatException('اسم النشاط ونوعه مطلوبان');
    }
    final phone = contactPhoneDisplay?.trim().isNotEmpty == true
        ? normalizeCustomerPhone(contactPhoneDisplay!)
        : null;
    final now = DateTime.now().toUtc().toIso8601String();
    final localId = 'biz-${_uuid.v4()}', requestId = _uuid.v4();
    final extra =
        additionalCurrencies
            .map((c) => c.toUpperCase())
            .where((c) => c != currencyCode.toUpperCase())
            .toSet()
            .toList()
          ..sort();
    if (logoBytes != null && logoBytes.length > 5 * 1024 * 1024) {
      throw const FormatException('حجم الشعار يتجاوز 5 ميجابايت');
    }
    final business = <String, dynamic>{
      'id': localId,
      'owner_user_id': owner,
      'name': name.trim(),
      'business_type': businessType.trim(),
      'currency_code': currencyCode.toUpperCase(),
      'additional_currencies': jsonEncode(extra),
      'country_code': countryCode.toUpperCase(),
      'city': city?.trim(),
      'address': address?.trim(),
      'contact_phone': phone,
      'timezone': 'Asia/Aden',
      'is_active': 1,
      'created_at': now,
    };
    final db = await store.database;
    await db.transaction((txn) async {
      // The setup form may be submitted again after reopening or a double tap.
      final existing = await txn.query(
        'offline_mutations_queue',
        where: "command_type='create_business' AND status!='dead_letter'",
        limit: 1,
      );
      if (existing.isNotEmpty) {
        throw StateError(
          'يوجد طلب إنشاء نشاط محفوظ. انتظر مزامنته قبل إنشاء نشاط آخر',
        );
      }
      await txn.insert('local_businesses', business);
      await txn.insert('offline_mutations_queue', {
        'client_request_id': requestId,
        'command_type': 'create_business',
        'payload_json': jsonEncode({
          'p_profile': {
            'name': name.trim(),
            'business_type': businessType.trim(),
            'currency_code': currencyCode.toUpperCase(),
            'additional_currencies': extra,
            'country_code': countryCode.toUpperCase(),
            'city': city?.trim(),
            'address': address?.trim(),
            'contact_phone': phone,
          },
        }),
        'local_ref_id': localId,
        'status': 'pending',
        'attempt_count': 0,
        'created_at': now,
      });
      await txn.insert('local_sync_state', {
        'key': 'business_access_v1',
        'value': jsonEncode({
          'user_id': owner,
          'business_id': localId,
          'role': 'owner',
        }),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      if (logoBytes != null) {
        await txn.insert('offline_mutations_queue', {
          'client_request_id': _uuid.v4(),
          'command_type': 'upload_business_logo',
          'payload_json': jsonEncode({
            'businessId': localId,
            'bytes': base64Encode(logoBytes),
            'extension': logoExtension,
          }),
          'local_ref_id': localId,
          'status': 'pending',
          'attempt_count': 0,
          'depends_on_client_request_id': requestId,
          'created_at': now,
        });
      }
    });
    await store.rememberOwner();
    _requestSync();
    return business;
  }

  /// تحديث العملات الإضافية عبر أمر خادمي يمنع تعطيل عملة مستخدمة في قيود.
  Future<List<String>> updateBusinessCurrencies({
    required String businessId,
    required List<String> additionalCurrencies,
  }) async {
    final requested =
        additionalCurrencies
            .map((code) => code.trim().toUpperCase())
            .toSet()
            .toList()
          ..sort();
    if (requested.any((code) => !CurrencyCatalog.allowedCodes.contains(code))) {
      throw const MerchantApiException(
        code: 'unsupported_currency',
        message:
            'العملات المتاحة هي الريال اليمني والسعودي والدولار الأمريكي فقط.',
      );
    }
    final db = await AppDatabase.instance.database;
    final requestId = _uuid.v4();
    final now = DateTime.now().toUtc().toIso8601String();
    await db.transaction((txn) async {
      final rows = await txn.query(
        'local_businesses',
        where: 'id=?',
        whereArgs: [businessId],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('business_not_found');
      final base = (rows.first['currency_code'] as String).toUpperCase();
      if (!CurrencyCatalog.allowedCodes.contains(base) ||
          requested.contains(base)) {
        throw StateError('invalid_business_currencies');
      }
      final existing = await txn.query(
        'offline_mutations_queue',
        columns: ['id'],
        where:
            "local_ref_id=? AND command_type='update_business_currencies_idempotent' AND status!='dead_letter'",
        whereArgs: [businessId],
        limit: 1,
      );
      if (existing.isNotEmpty) throw StateError('currency_change_pending');
      final previous = rows.first['additional_currencies'] as String? ?? '[]';
      await txn.update(
        'local_businesses',
        {'additional_currencies': jsonEncode(requested)},
        where: 'id=?',
        whereArgs: [businessId],
      );
      await txn.insert('offline_mutations_queue', {
        'client_request_id': requestId,
        'command_type': 'update_business_currencies_idempotent',
        'payload_json': jsonEncode({
          'p_business_id': businessId,
          'p_additional_currencies': requested,
          'previous': previous,
        }),
        'local_ref_id': businessId,
        'status': 'pending',
        'attempt_count': 0,
        'created_at': now,
      });
    });
    _requestSync();
    return requested;
  }

  Future<void> updateBusinessLogo({
    required String businessId,
    required Uint8List bytes,
    required String extension,
  }) async {
    final normalizedBytes = await prepareBusinessLogo(bytes);
    final requestId = _uuid.v4();
    final db = await AppDatabase.instance.database;
    await db.transaction((txn) async {
      final businesses = await txn.query(
        'local_businesses',
        columns: ['owner_user_id'],
        where: 'id=?',
        whereArgs: [businessId],
        limit: 1,
      );
      if (businesses.isEmpty ||
          AppDatabase.instance.accountId == null ||
          businesses.first['owner_user_id'] != AppDatabase.instance.accountId) {
        throw const MerchantApiException(
          code: '42501',
          message: 'تغيير الشعار متاح لمالك المتجر فقط.',
        );
      }
      final existing = await txn.query(
        'offline_mutations_queue',
        columns: ['id'],
        where:
            "local_ref_id=? AND command_type='upload_business_logo' AND status!='dead_letter'",
        whereArgs: [businessId],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        throw const MerchantApiException(
          code: 'logo_change_pending',
          message:
              'يوجد شعار محفوظ بانتظار المزامنة. انتظر اكتمال رفعه قبل تغييره.',
        );
      }
      await txn.insert('offline_mutations_queue', {
        'client_request_id': requestId,
        'command_type': 'upload_business_logo',
        'payload_json': jsonEncode({
          'businessId': businessId,
          'bytes': base64Encode(normalizedBytes),
          'extension': 'png',
        }),
        'local_ref_id': businessId,
        'status': 'pending',
        'attempt_count': 0,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
    });
    _requestSync();
  }

  /// تحديث ملف المنشأة محلياً فوراً ثم مزامنته مع الخادم.
  Future<void> updateBusinessProfile({
    required String businessId,
    required String name,
    required String businessType,
    required String countryCode,
    required String city,
    required String address,
    required String contactPhone,
    required String timezone,
  }) async {
    final now = DateTime.now().toIso8601String();
    final serverValues = <String, dynamic>{
      'name': name.trim(),
      'business_type': businessType.trim(),
      'country_code': countryCode.trim().toUpperCase(),
      'city': city.trim().isEmpty ? null : city.trim(),
      'address': address.trim().isEmpty ? null : address.trim(),
      'contact_phone_display': contactPhone.trim().isEmpty
          ? null
          : contactPhone.trim(),
      'timezone': timezone,
      'updated_at': now,
    };
    final db = await AppDatabase.instance.database;
    await db.transaction((txn) async {
      await txn.update(
        'local_businesses',
        {
          'name': name.trim(),
          'business_type': businessType.trim(),
          'country_code': countryCode.trim().toUpperCase(),
          'city': city.trim(),
          'address': address.trim(),
          'contact_phone': contactPhone.trim(),
          'timezone': timezone,
        },
        where: 'id = ?',
        whereArgs: [businessId],
      );
      await txn.insert('offline_mutations_queue', {
        'client_request_id': _uuid.v4(),
        'command_type': RpcContract.cmdUpdateBusinessProfile,
        'payload_json': jsonEncode({'businessId': businessId, ...serverValues}),
        'local_ref_id': businessId,
        'status': 'pending',
        'attempt_count': 0,
        'created_at': now,
      });
    });
    _requestSync();
  }

  /// قراءة بيانات عميل محدد
  Future<BusinessCustomerModel?> getCustomer(String customerId) async {
    final row = await AppDatabase.instance.getCustomerById(customerId);
    if (row == null) return null;
    final currencyBals = await AppDatabase.instance.getCustomerCurrencyBalances(
      customerId,
    );
    return BusinessCustomerModel.fromMap(row, currencyBals);
  }

  Future<void> updateCustomer({
    required String customerId,
    required String displayName,
    String? note,
    double? creditLimit,
    int? defaultDueDays,
  }) async {
    if (displayName.trim().length < 2 ||
        displayName.trim().length > 120 ||
        (note?.length ?? 0) > 2000 ||
        (creditLimit != null && creditLimit < 0) ||
        (defaultDueDays != null &&
            (defaultDueDays < 0 || defaultDueDays > 3650))) {
      throw const FormatException('بيانات العميل غير صالحة');
    }
    await AppDatabase.instance.queueCustomerProfileChange(
      customerId,
      {
        'local_display_name': displayName.trim(),
        'local_note': note?.trim(),
        'credit_limit': creditLimit,
        'credit_limit_minor': creditLimit == null
            ? null
            : Money.fromNum(creditLimit).minorUnits,
        'default_due_days': defaultDueDays,
      },
      {
        'p_business_customer_id': customerId,
        'p_action': 'update',
        'p_profile': {
          'display_name': displayName.trim(),
          'note': note?.trim(),
          'credit_limit': creditLimit,
          'default_due_days': defaultDueDays,
        },
      },
    );
    _requestSync();
  }

  Future<void> archiveCustomer(String customerId) async {
    await AppDatabase.instance.queueCustomerProfileChange(
      customerId,
      {'is_archived': 1},
      {
        'p_business_customer_id': customerId,
        'p_action': 'archive',
        'p_profile': <String, dynamic>{},
      },
    );
    _requestSync();
  }

  /// قراءة القيود المالية للعميل من الكاش المحلي
  Future<List<LedgerEntryModel>> getLedgerEntries(
    String businessCustomerId, {
    String? currencyCode,
  }) async {
    final rows = await AppDatabase.instance.getLedgerEntries(
      businessCustomerId,
      currencyCode: currencyCode,
    );
    return rows.map((e) => LedgerEntryModel.fromMap(e)).toList();
  }

  /// إضافة عميل جديد عبر Edge Function ‏`customer-directory` (قرار كبير
  /// المعماريين رقم 4 / خطة 06-D4): تطبيع E164، بحث hash، إنشاء customers،
  /// تشفير الهاتف، ربط العلاقة، وطلب ربط اختياري — كلها ذرّياً في الخادم.
  ///
  /// أونلاين: يُخزَّن العميل محلياً بالمعرّف الخادمي الحقيقي (synced).
  /// أوفلاين: يُحفظ محلياً بمعرّف `cust-*` وعلم `pending_directory` ويُدرج
  /// أمر `customer_directory` في طابور المزامنة؛ عند نجاح الأمر يستدعي محرك
  /// المزامنة [reconcileBusinessCustomerId] لتسوية المعرّفات (خطة 02 §3.4).
  Future<BusinessCustomerModel> addCustomer({
    required String businessId,
    required String localDisplayName,
    String? phone,
    String? localNote,
    double? creditLimit,
    int? defaultDueDays,
  }) async {
    final rawPhone = phone?.trim() ?? '';
    final trimmedPhone = rawPhone.isEmpty
        ? ''
        : normalizeCustomerPhone(rawPhone);
    if (trimmedPhone.isNotEmpty) {
      final db = await AppDatabase.instance.database;
      final duplicates = await db.query(
        'local_business_customers',
        columns: ['id'],
        where: 'business_id=? AND phone=?',
        whereArgs: [businessId, trimmedPhone],
        limit: 1,
      );
      if (duplicates.isNotEmpty) {
        throw const MerchantApiException(
          code: 'customer_exists',
          message: 'رقم الهاتف مسجل لدى عميل في هذا النشاط',
        );
      }
    }
    final now = DateTime.now().toIso8601String();
    // Local-first دائماً: لا تنتظر الشاشة الشبكة. يتولى SyncEngine الإرسال.
    final localId = 'cust-${_uuid.v4()}';
    final customer = BusinessCustomerModel(
      id: localId,
      businessId: businessId,
      localDisplayName: localDisplayName.trim(),
      phone: trimmedPhone.isNotEmpty ? trimmedPhone : null,
      localNote: localNote?.trim(),
      creditLimit: creditLimit,
      defaultDueDays: defaultDueDays,
      linkStatus: 'unlinked',
      currentBalance: 0.0,
      amountCustomerOwes: 0.0,
      amountBusinessOwesCustomer: 0.0,
      currencyBalances: const {},
      syncStatus: 'pending_insert',
      createdAt: now,
      updatedAt: now,
    );

    final payload = {
      'businessId': businessId,
      if (trimmedPhone.isNotEmpty) 'phone': trimmedPhone,
      'localDisplayName': localDisplayName.trim(),
      'localNote': ?localNote?.trim(),
      'creditLimit': ?creditLimit,
      'defaultDueDays': ?defaultDueDays,
      'requestLink': trimmedPhone.isNotEmpty,
      'localCustomerId': localId,
    };
    final db = await AppDatabase.instance.database;
    await db.transaction((txn) async {
      final parent = await txn.query(
        'offline_mutations_queue',
        columns: ['client_request_id'],
        where: 'command_type = ? AND local_ref_id = ?',
        whereArgs: ['create_business', businessId],
        limit: 1,
      );
      await txn.insert(
        'local_business_customers',
        customer.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await txn.insert('offline_mutations_queue', {
        'client_request_id': _uuid.v4(),
        'command_type': RpcContract.cmdCustomerDirectory,
        if (parent.isNotEmpty)
          'depends_on_client_request_id': parent.first['client_request_id'],
        'payload_json': jsonEncode(payload),
        'local_ref_id': localId,
        'status': 'pending',
        'attempt_count': 0,
        'created_at': now,
      });
    });
    _requestSync();
    return customer;
  }

  /// تسوية المعرّفات بعد نجاح أمر `customer_directory` من الطابور:
  /// تستبدل المعرّف المحلي `cust-*` بالمعرّف الخادمي في جدول العملاء وكل
  /// القيود المحلية وأرصدة العملات وحمولات الأوامر المعلقة (خطة 02 §3.4-3 —
  /// شرط صحّة: بلاها يفشل FK لكل قيد لاحق).
  ///
  /// يستدعيها محرك المزامنة (ملك وكيل المزامنة) بعد استلام `businessCustomerId`
  /// من استجابة customer-directory.
  Future<void> reconcileBusinessCustomerId({
    required String localCustomerId,
    required String serverBusinessCustomerId,
    String? serverCustomerId,
    String? linkStatus,
  }) async {
    final db = await AppDatabase.instance.database;
    final now = DateTime.now().toIso8601String();

    await db.transaction((txn) async {
      // 1) صف العميل نفسه
      await txn.update(
        'local_business_customers',
        {
          'id': serverBusinessCustomerId,
          'customer_id': ?serverCustomerId,
          'link_status': ?linkStatus,
          'sync_status': 'synced',
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [localCustomerId],
      );

      // 2) كل القيود المحلية المعلقة التي تشير للمعرّف المحلي
      await txn.update(
        'local_ledger_entries',
        {'business_customer_id': serverBusinessCustomerId},
        where: 'business_customer_id = ?',
        whereArgs: [localCustomerId],
      );

      // 3) أرصدة العملات (مع مفتاحها الأساسي المشتق bal-<cust>-<currency>)
      await txn.rawUpdate(
        "UPDATE local_customer_currency_balances "
        "SET business_customer_id = ?, "
        "    id = 'bal-' || ? || '-' || currency_code, "
        "    updated_at = ? "
        "WHERE business_customer_id = ?",
        [
          serverBusinessCustomerId,
          serverBusinessCustomerId,
          now,
          localCustomerId,
        ],
      );

      // 4) حمولات الأوامر المعلقة التي تشير للمعرّف المحلي
      final pending = await txn.query(
        'offline_mutations_queue',
        where: 'payload_json LIKE ?',
        whereArgs: ['%$localCustomerId%'],
      );
      for (final row in pending) {
        final payload =
            jsonDecode(row['payload_json'] as String) as Map<String, dynamic>;
        var changed = false;
        payload.forEach((key, value) {
          if (value == localCustomerId) {
            payload[key] = serverBusinessCustomerId;
            changed = true;
          }
        });
        // مفتاح التسوية المؤقت لا يُرسل للخادم
        if (payload.remove('localCustomerId') != null) changed = true;
        if (changed) {
          await txn.update(
            'offline_mutations_queue',
            {'payload_json': jsonEncode(payload)},
            where: 'id = ?',
            whereArgs: [row['id']],
          );
        }
      }
    });
  }

  /// إنشاء قيد مالي جديد (دين / دفعة) مع التصنيف وطرق السداد.
  ///
  /// الحمولة بالتوقيع الموسع (ترحيل توحيد العقد): التصنيف/السداد/المرجع تُرسل
  /// للخادم، والعملة تُشتق خلفياً من المحل (لا يُرسل p_currency_code — قرار 1)،
  /// و`p_attachment_url` يبقى null حتى خط أنابيب المرفقات (قرار 19).
  Future<String> _validatedCurrencyAmount(
    double amount,
    String currencyCode,
  ) async {
    final code = currencyCode.trim().toUpperCase();
    if (!CurrencyCatalog.allowedCodes.contains(code) ||
        !amount.isFinite ||
        amount <= 0 ||
        amount > 900000000000000) {
      throw const MerchantApiException(
        code: 'invalid_amount',
        message: 'أدخل مبلغًا موجبًا وعملة صحيحة.',
      );
    }
    final currencies = await AppDatabase.instance.getCurrencies();
    final scale = CurrencyCatalog.forCode(
      code,
      currencies.isEmpty ? CurrencyCatalog.defaults : currencies,
    ).decimalScale;
    try {
      return Money.fromCurrencyText(
        amount.toString(),
        decimalScale: scale,
      ).toDecimalString();
    } on FormatException {
      throw MerchantApiException(
        code: 'invalid_currency_precision',
        message: 'المبلغ لا يطابق دقة العملة $code ($scale منازل عشرية).',
      );
    }
  }

  Future<LedgerEntryModel> createLedgerEntry({
    required String businessId,
    required String businessCustomerId,
    required String entryType, // 'debt' or 'payment'
    required double amount,
    required String description,
    required String currencyCode,
    String category = 'goods',
    String paymentMethod = 'cash',
    String? referenceNumber,
    String? bankOrAgentName,
    String? attachmentPath,
    String? dueDate,
    String? externalReference,
  }) async {
    final canonicalAmount = await _validatedCurrencyAmount(
      amount,
      currencyCode,
    );
    amount = double.parse(canonicalAmount);
    currencyCode = currencyCode.trim().toUpperCase();
    final clientRequestId = _uuid.v4();
    final entryId = 'entry-$clientRequestId';
    final now = DateTime.now().toIso8601String();
    final direction = entryType == 'debt' ? 'debit' : 'credit';

    final entry = LedgerEntryModel(
      id: entryId,
      businessId: businessId,
      businessCustomerId: businessCustomerId,
      entryType: entryType,
      direction: direction,
      amount: amount,
      currencyCode: currencyCode,
      category: category,
      paymentMethod: paymentMethod,
      referenceNumber: referenceNumber,
      bankOrAgentName: bankOrAgentName,
      attachmentPath: attachmentPath,
      description: description.trim(),
      occurredAt: now,
      dueDate: dueDate,
      externalReference: externalReference,
      clientRequestId: clientRequestId,
      confirmationStatus: 'not_available',
      disputeStatus: 'none',
      isReversed: false,
      syncStatus: 'pending_insert',
      createdAt: now,
    );

    final payload = RpcContract.createLedgerEntryPayload(
      businessCustomerId: businessCustomerId,
      entryType: entryType,
      amount: amount,
      description: description.trim(),
      category: category,
      paymentMethod: paymentMethod,
      referenceNumber: referenceNumber,
      bankOrAgentName: bankOrAgentName,
      attachmentUrl: null, // المرفقات تُرفع بعد المزامنة (خطة 06-D5)
      occurredAt: now,
      dueDate: dueDate,
      externalReference: externalReference,
      clientRequestId: clientRequestId,
      sourceDeviceId: null, // يُملأ من تسجيل الجهاز عند توفره
      currencyCode: currencyCode,
    );

    // حفظ أوفلاين فوري في الكاش المحلي وتحديث أرصدة العملات
    await AppDatabase.instance.saveLedgerEntryOptimistic(
      entry: entry.toMap(),
      commandType: RpcContract.cmdCreateLedgerEntry,
      payload: payload,
      dependentMutation: attachmentPath == null
          ? null
          : {
              'client_request_id': _uuid.v4(),
              'command_type': 'upload_attachment',
              'local_ref_id': entryId,
              'payload': {
                'localPath': attachmentPath,
                'entityId': entryId,
                'filename': p.basename(attachmentPath),
                'mimeType': _attachmentMimeType(attachmentPath),
              },
            },
    );

    // إطلاق محرك المزامنة في الخلفية
    _requestSync();

    return entry;
  }

  static String _attachmentMimeType(String path) {
    final extension = p.extension(path).toLowerCase();
    return switch (extension) {
      '.png' => 'image/png',
      '.webp' => 'image/webp',
      '.pdf' => 'application/pdf',
      _ => 'image/jpeg',
    };
  }

  /// تطبيق خصم للعميل (Discount) — بلا معامل عملة (الخصم بعملة المحل حصراً)
  Future<LedgerEntryModel> applyCustomerDiscount({
    required String businessId,
    required String businessCustomerId,
    required double amount,
    required String description,
    required String currencyCode,
  }) async {
    final canonicalAmount = await _validatedCurrencyAmount(
      amount,
      currencyCode,
    );
    amount = double.parse(canonicalAmount);
    currencyCode = currencyCode.trim().toUpperCase();
    final clientRequestId = _uuid.v4();
    final entryId = 'entry-$clientRequestId';
    final now = DateTime.now().toIso8601String();

    final entry = LedgerEntryModel(
      id: entryId,
      businessId: businessId,
      businessCustomerId: businessCustomerId,
      entryType: 'discount',
      direction: 'credit',
      amount: amount,
      currencyCode: currencyCode,
      category: 'discount',
      paymentMethod: 'discount',
      description: description.trim(),
      occurredAt: now,
      clientRequestId: clientRequestId,
      confirmationStatus: 'not_available',
      disputeStatus: 'none',
      isReversed: false,
      syncStatus: 'pending_insert',
      createdAt: now,
    );

    final payload = RpcContract.applyCustomerDiscountPayload(
      businessCustomerId: businessCustomerId,
      amount: amount,
      description: description.trim(),
      clientRequestId: clientRequestId,
      currencyCode: currencyCode,
    );

    await AppDatabase.instance.saveLedgerEntryOptimistic(
      entry: entry.toMap(),
      commandType: RpcContract.cmdApplyCustomerDiscount,
      payload: payload,
    );

    _requestSync();

    return entry;
  }

  Future<LedgerEntryModel> applyDiscount({
    required String businessId,
    required String businessCustomerId,
    required double amount,
    required String description,
    required String currencyCode,
  }) => applyCustomerDiscount(
    businessId: businessId,
    businessCustomerId: businessCustomerId,
    amount: amount,
    description: description,
    currencyCode: currencyCode,
  );

  /// عكس قيد مالي (Reversal).
  ///
  /// تنبيه عقدي: `p_entry_id` يجب أن يكون المعرف **الخادمي** للقيد؛ عكس قيد
  /// لم يُزامن بعد محظور في الواجهة (خطة 06 خطوة 3.8).
  Future<LedgerEntryModel> reverseLedgerEntry({
    required String businessId,
    required String originalEntryId,
    required String businessCustomerId,
    required String originalEntryType,
    required String originalDirection,
    required double originalAmount,
    required String reason,
    required String currencyCode,
  }) async {
    currencyCode = currencyCode.trim().toUpperCase();
    if (!_uuidRegex.hasMatch(originalEntryId)) {
      throw const MerchantApiException(
        code: 'unsynced_reversal_target',
        message: 'زامن القيد الأصلي قبل عكسه.',
      );
    }
    final clientRequestId = _uuid.v4();
    final entryId = 'entry-$clientRequestId';
    final now = DateTime.now().toIso8601String();

    // الاتجاه المعاكس للقيد الأصلي
    final reverseDirection = originalDirection == 'debit' ? 'credit' : 'debit';

    final entry = LedgerEntryModel(
      id: entryId,
      businessId: businessId,
      businessCustomerId: businessCustomerId,
      entryType: 'reversal',
      direction: reverseDirection,
      amount: originalAmount,
      currencyCode: currencyCode,
      description: 'عكس قيد: ${reason.trim()}',
      occurredAt: now,
      clientRequestId: clientRequestId,
      confirmationStatus: 'not_available',
      disputeStatus: 'none',
      isReversed: false,
      syncStatus: 'pending_insert',
      createdAt: now,
    );

    final payload = RpcContract.reverseLedgerEntryPayload(
      entryId: originalEntryId,
      reason: reason.trim(),
      clientRequestId: clientRequestId,
    );

    await AppDatabase.instance.saveLedgerEntryOptimistic(
      entry: entry.toMap(),
      commandType: RpcContract.cmdReverseLedgerEntry,
      payload: payload,
      reversalOfEntryId: originalEntryId,
    );

    _requestSync();

    return entry;
  }

  // ==================== عمليات الاعتراضات والنزاعات (Disputes) ====================

  /// الاعتراضات وبيانات القيد والعميل من SQLite؛ يتولى SyncEngine تحديثها.
  Future<List<DisputeModel>> getDisputes(String businessId) =>
      _getLocalDisputes(businessId);

  Future<List<DisputeModel>> _getLocalDisputes(String businessId) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.rawQuery(
      '''SELECT d.*, c.local_display_name,
      e.amount AS entry_amount, e.description AS entry_description,
      e.entry_type, e.occurred_at AS entry_occurred_at, e.currency_code
      FROM local_disputes d LEFT JOIN local_ledger_entries e ON e.id=d.entry_id
      LEFT JOIN local_business_customers c ON c.id=e.business_customer_id
      WHERE d.business_id=? ORDER BY d.created_at DESC,d.id''',
      [businessId],
    );
    return rows.map((e) => DisputeModel.fromMap(e)).toList();
  }

  /// Dashboard reads the synchronized cache; network pulls belong to SyncEngine.
  Future<List<DisputeModel>> getCachedDisputes(String businessId) =>
      _getLocalDisputes(businessId);

  /// محادثة النزاع (خطة 06 خطوة 3.4): العمود الفعلي `sender_user_id`
  /// (وليس `sender_id` الشبح)، وبلا تضمين profiles (لا FK وسياسة
  /// profiles_select_own تمنع قراءة الآخرين). تسمية المرسل تُشتق في العميل.
  Future<List<DisputeMessageModel>> getDisputeMessages(String disputeId) async {
    final owner = AppDatabase.instance.accountId;
    final rows = await AppDatabase.instance.getLocalDisputeMessages(disputeId);
    return rows
        .map((r) => DisputeMessageModel.fromMap(r, currentUserId: owner))
        .toList();
  }

  /// يحفظ الرسالة وطلب إرسالها ذرياً قبل تشغيل المزامنة الخلفية.
  Future<bool> addDisputeMessage(String disputeId, String message) async {
    final text = message.trim();
    if (text.isEmpty || text.length > 2000) {
      throw const FormatException('رسالة الاعتراض غير صالحة');
    }
    final accountId = AppDatabase.instance.accountId;
    if (accountId == null) {
      throw const MerchantApiException(
        code: 'unauthenticated',
        message: 'سجل الدخول لإرسال الرسالة.',
      );
    }
    final requestId = _uuid.v4();
    final now = DateTime.now().toUtc().toIso8601String();
    final db = await AppDatabase.instance.database;
    await db.transaction((txn) async {
      final savedDecision = await txn.query(
        'offline_mutations_queue',
        columns: ['id'],
        where: "command_type='resolve_dispute' AND local_ref_id=?",
        whereArgs: [disputeId],
        limit: 1,
      );
      if (savedDecision.isNotEmpty) {
        throw StateError(
          'يوجد قرار محفوظ لهذا الاعتراض. راجع نتيجة إرساله قبل إضافة رد.',
        );
      }
      final cached = await txn.query(
        'local_disputes',
        where: 'id=?',
        whereArgs: [disputeId],
        limit: 1,
      );
      if (cached.isEmpty || !DisputeModel.fromMap(cached.single).isOpen) {
        throw StateError('هذا الاعتراض مغلق أو غير متاح للرد.');
      }
      await txn.insert('local_dispute_messages', {
        'id': 'message-$requestId',
        'dispute_id': disputeId,
        'sender_user_id': accountId,
        'sender_workspace': 'merchant',
        'message': text,
        'created_at': now,
        'sync_status': 'pending',
        'client_request_id': requestId,
      });
      await txn.insert('offline_mutations_queue', {
        'client_request_id': requestId,
        'command_type': 'add_dispute_message',
        'payload_json': jsonEncode({
          'p_dispute_id': disputeId,
          'p_message': text,
          'p_client_request_id': requestId,
          'p_sender_workspace': 'merchant',
        }),
        'local_ref_id': 'message-$requestId',
        'status': 'pending',
        'attempt_count': 0,
        'created_at': now,
      });
    });
    _requestSync();
    return true;
  }

  /// حل نزاع — RPC `resolve_dispute` مع `p_resolution_note`
  /// (تصحيح الاسم + p_note → p_resolution_note، خطة 06 خطوة 3.2).
  Future<bool> resolveDispute({
    required String disputeId,
    required String resolution,
    required String note,
    double? correctedAmount,
  }) async {
    if (!{'accepted', 'partially_accepted', 'rejected'}.contains(resolution) ||
        note.trim().isEmpty ||
        note.trim().length > 4000) {
      throw const FormatException('حدد القرار واكتب سببًا واضحًا.');
    }
    final db = await AppDatabase.instance.database;
    await db.transaction((tx) async {
      final disputes = await tx.query(
        'local_disputes',
        where: 'id=?',
        whereArgs: [disputeId],
        limit: 1,
      );
      if (disputes.isEmpty || !DisputeModel.fromMap(disputes.single).isOpen) {
        throw StateError('هذا الاعتراض غير متاح للمعالجة. حدّث بيانات الحساب.');
      }
      final entries = await tx.query(
        'local_ledger_entries',
        columns: ['amount'],
        where: 'id=?',
        whereArgs: [disputes.single['entry_id']],
        limit: 1,
      );
      final amount = entries.isEmpty
          ? null
          : (entries.single['amount'] as num).toDouble();
      if (resolution == 'partially_accepted' &&
          (amount == null ||
              correctedAmount == null ||
              correctedAmount <= 0 ||
              correctedAmount >= amount)) {
        throw const FormatException(
          'المبلغ المصحح يجب أن يكون أكبر من صفر وأقل من مبلغ العملية.',
        );
      }
      if (resolution != 'partially_accepted' && correctedAmount != null) {
        throw const FormatException(
          'التصحيح المالي متاح مع القبول الجزئي فقط.',
        );
      }
      final pending = await tx.query(
        'offline_mutations_queue',
        where: "command_type='resolve_dispute' AND local_ref_id=?",
        whereArgs: [disputeId],
        limit: 1,
      );
      if (pending.isNotEmpty) {
        throw StateError(
          'يوجد قرار محفوظ لهذا الاعتراض. راجع نتيجة إرساله أولًا.',
        );
      }
      final request = _uuid.v4();
      await tx.insert('offline_mutations_queue', {
        'client_request_id': request,
        'command_type': 'resolve_dispute',
        'payload_json': jsonEncode({
          'p_dispute_id': disputeId,
          'p_resolution': resolution,
          'p_resolution_note': note.trim(),
          'p_corrected_amount': correctedAmount,
          'p_client_request_id': request,
        }),
        'local_ref_id': disputeId,
        'status': 'pending',
        'attempt_count': 0,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
    });
    _requestSync();
    return true;
  }

  Future<bool> hasPendingDisputeResolution(String disputeId) async {
    return await getDisputeResolutionQueue(disputeId) != null;
  }

  Future<Map<String, dynamic>?> getDisputeResolutionQueue(
    String disputeId,
  ) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query(
      'offline_mutations_queue',
      columns: ['status', 'payload_json', 'last_error'],
      where: "command_type='resolve_dispute' AND local_ref_id=?",
      whereArgs: [disputeId],
      limit: 1,
    );
    return rows.firstOrNull;
  }

  // ==================== كشوفات الحساب المجمعة (Statements) ====================

  Future<StatementModel?> generateStatement({
    required String businessCustomerId,
    required String periodFrom,
    required String periodTo,
    String? currencyCode,
  }) => generateCustomerStatement(
    businessCustomerId: businessCustomerId,
    periodFrom: periodFrom,
    periodTo: periodTo,
    currencyCode: currencyCode,
  );

  /// ينشئ كشفاً مستقلاً لكل عملة ثم يجمعها في ملف PDF واحد. لا يتم جمع
  /// أرصدة عملات مختلفة حسابياً؛ كل عملة تبقى في صفحاتها الخاصة.
  Future<StatementModel?> generateAllCurrenciesStatement({
    required String businessCustomerId,
    required String periodFrom,
    required String periodTo,
    required List<String> currencyCodes,
  }) async {
    final codes = currencyCodes
        .map((c) => c.trim().toUpperCase())
        .toSet()
        .toList();
    if (codes.isEmpty || codes.any((c) => !RegExp(r'^[A-Z]{3}$').hasMatch(c))) {
      throw const FormatException('حدد عملة صالحة للكشف.');
    }
    final statements = <StatementModel>[];
    for (final code in codes) {
      statements.add(
        await _generateLocalStatement(
          businessCustomerId: businessCustomerId,
          periodFrom: periodFrom,
          periodTo: periodTo,
          currencyCode: code,
        ),
      );
    }
    return statements.first.copyWith(
      combinedStatements: statements.length > 1 ? statements : const [],
    );
  }

  /// A combined PDF must contain exactly one downloadable statement per currency.
  static List<StatementModel> requireCompleteStatements(
    List<String> currencyCodes,
    List<StatementModel?> results,
  ) {
    if (currencyCodes.length != results.length ||
        results.any((statement) => statement == null)) {
      throw const MerchantApiException(
        code: 'incomplete_currency_statement',
        message: 'تعذر إنشاء كشف كامل لكل العملات. حاول مرة أخرى.',
      );
    }
    final statements = results.cast<StatementModel>();
    for (var index = 0; index < currencyCodes.length; index++) {
      if (statements[index].currencyCode.toUpperCase() !=
          currencyCodes[index].toUpperCase()) {
        throw const MerchantApiException(
          code: 'statement_currency_mismatch',
          message: 'لم تتطابق عملات الكشف المطلوب. حاول مرة أخرى.',
        );
      }
    }
    if (statements.length > 1 &&
        statements.any((statement) => statement.downloadUrl == null)) {
      throw const MerchantApiException(
        code: 'combined_statement_requires_connection',
        message:
            'يتطلب جمع كشف كل العملات اتصالًا بالإنترنت. أنشئ كشف كل عملة على حدة عند العمل دون اتصال.',
      );
    }
    return statements;
  }

  /// توليد كشف — RPC `create_statement` مع `p_scope='business_customer'`
  /// (تصحيح الاسم الشبح command_generate_statement وقيمة scope، خطة 06 خطوة 3.7).
  /// توليد الـ PDF لاحقاً عبر Edge Function ‏generate-statement (خطة 06 خطوة 5.4).
  Future<StatementModel?> generateCustomerStatement({
    required String businessCustomerId,
    required String periodFrom,
    required String periodTo,
    String? currencyCode,
  }) async {
    return _generateLocalStatement(
      businessCustomerId: businessCustomerId,
      periodFrom: periodFrom,
      periodTo: periodTo,
      currencyCode: currencyCode,
    );
  }

  /// يبني ملخص الكشف من دفتر SQLite فوراً، ثم يضع طلب إنشاء PDF الموثق
  /// في طابور المزامنة. لا تُجمع العملات حسابياً؛ لكل عملة طلب مستقل.
  Future<StatementModel> _generateLocalStatement({
    required String businessCustomerId,
    required String periodFrom,
    required String periodTo,
    String? currencyCode,
  }) async {
    final code = (currencyCode ?? 'YER').toUpperCase();
    final from = DateTime.parse(periodFrom);
    final to = DateTime.parse(periodTo);
    final rows = await AppDatabase.instance.getLedgerEntries(
      businessCustomerId,
      currencyCode: code,
    );

    final totals = LocalStatementTotals.calculate(
      entries: rows.map(LedgerEntryModel.fromMap),
      from: from,
      to: to,
      currencyCode: code,
    );

    final localId = 'statement-local-${_uuid.v4()}';
    await AppDatabase.instance.enqueueMutation(
      commandType: RpcContract.cmdGenerateStatement,
      localRefId: localId,
      payload: {
        'businessCustomerId': businessCustomerId,
        'periodFrom': periodFrom,
        'periodTo': periodTo,
        'currencyCode': code,
      },
    );
    _requestSync();

    return StatementModel(
      id: localId,
      scope: 'business_customer',
      businessCustomerId: businessCustomerId,
      periodFrom: periodFrom,
      periodTo: periodTo,
      currencyCode: code,
      openingBalance: totals.opening.toDouble(),
      totalDebits: totals.debits.toDouble(),
      totalCredits: totals.credits.toDouble(),
      closingBalance: totals.closing.toDouble(),
      verificationCode: 'LOCAL-PENDING',
      createdAt: DateTime.now().toIso8601String(),
      localEntries: rows
          .where((r) {
            final date = DateTime.parse(r['occurred_at'] as String);
            return !date.isBefore(from) && date.isBefore(to);
          })
          .map((r) => Map<String, dynamic>.from(r))
          .toList(),
    );
  }
}
