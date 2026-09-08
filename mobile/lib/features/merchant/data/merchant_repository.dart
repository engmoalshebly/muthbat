import 'dart:convert';
import 'package:flutter/foundation.dart';

import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../../../core/config/supabase_config.dart';
import '../../../core/sync/sync_engine.dart';
import 'merchant_api_exception.dart';
import 'models/business_customer_model.dart';
import 'models/dispute_message_model.dart';
import 'models/dispute_model.dart';
import 'models/ledger_entry_model.dart';
import 'models/member_model.dart';
import 'models/statement_model.dart';
import 'rpc_contract.dart';

/// مستودع بيانات التاجر.
///
/// كل أسماء RPC وحمولاتها تمر عبر [RpcContract] المركزي (خطة 02 خطوة 4)،
/// وكل الأخطاء تُرمى كـ [MerchantApiException] غنية — ممنوع `return false/null`
/// الصامت (خطة 06 خطوة 3.9).
class MerchantRepository {
  final _uuid = const Uuid();

  static final RegExp _uuidRegex = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  /// قراءة قائمة العملاء من الكاش المحلي مع إرفاق أرصدة العملات المتعددة
  Future<List<BusinessCustomerModel>> getCustomers(
    String businessId, {
    String? searchQuery,
  }) async {
    final rows = await AppDatabase.instance.getBusinessCustomers(
      businessId,
      searchQuery: searchQuery,
    );
    final List<BusinessCustomerModel> result = [];

    for (final row in rows) {
      final custId = row['id'] as String;
      final currencyBals = await AppDatabase.instance
          .getCustomerCurrencyBalances(custId);
      result.add(BusinessCustomerModel.fromMap(row, currencyBals));
    }
    return result;
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
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) {
      throw const MerchantApiException(
        code: 'unauthenticated',
        message: 'لم يتم تسجيل الدخول. سجّل دخولك أولاً.',
      );
    }

    final now = DateTime.now().toIso8601String();
    final client = Supabase.instance.client;

    try {
      final res = await client.rpc(
        RpcContract.createBusiness,
        params: {
          'p_name': name.trim(),
          'p_business_type': businessType.trim(),
          'p_currency_code': currencyCode.toUpperCase(),
          'p_additional_currencies': additionalCurrencies
              .map((code) => code.toUpperCase())
              .toList(),
          'p_country_code': countryCode.toUpperCase(),
          'p_city': city?.trim(),
          'p_address': address?.trim(),
        },
      );

      final businessId = res as String;
      String? logoPath;
      if (logoBytes != null) {
        final safeExtension =
            {'jpg', 'jpeg', 'png', 'webp'}.contains(logoExtension.toLowerCase())
            ? logoExtension.toLowerCase()
            : 'jpg';
        logoPath = '$businessId/logo.$safeExtension';
        try {
          await client.storage
              .from('business-assets')
              .uploadBinary(
                logoPath,
                logoBytes,
                fileOptions: const FileOptions(upsert: true),
              );
        } catch (e) {
          // الشعار اختياري؛ لا نلغي إنشاء المنشأة إذا فشل رفعه.
          debugPrint('[MerchantRepository] logo upload deferred: $e');
          logoPath = null;
        }
      }
      if (logoPath != null ||
          (contactPhoneDisplay?.trim().isNotEmpty ?? false)) {
        await client
            .from('businesses')
            .update({
              if (logoPath != null) 'logo_path': logoPath,
              if (contactPhoneDisplay?.trim().isNotEmpty ?? false)
                'contact_phone_display': contactPhoneDisplay!.trim(),
            })
            .eq('id', businessId);
      }
      final bizData = {
        'id': businessId,
        'owner_user_id': user.id,
        'name': name.trim(),
        'business_type': businessType.trim(),
        'currency_code': currencyCode.toUpperCase(),
        'additional_currencies': jsonEncode(
          additionalCurrencies.map((code) => code.toUpperCase()).toList(),
        ),
        'country_code': countryCode.toUpperCase(),
        'city': city?.trim(),
        'address': address?.trim(),
        'contact_phone': contactPhoneDisplay?.trim(),
        'logo_path': logoPath,
        'timezone': 'Asia/Aden',
        'is_active': 1,
        'created_at': now,
      };

      await AppDatabase.instance.saveBusiness(bizData);
      return bizData;
    } catch (e) {
      if (!MerchantApiException.isNetworkError(e)) {
        throw MerchantApiException.from(e);
      }

      // المسار الأوفلاين: حفظ محلي + إدراج في طابور الأوامر
      final localBizId = 'biz-${_uuid.v4()}';
      final clientRequestId = _uuid.v4();

      final bizData = {
        'id': localBizId,
        'owner_user_id': user.id,
        'name': name.trim(),
        'business_type': businessType.trim(),
        'currency_code': currencyCode.toUpperCase(),
        'additional_currencies': jsonEncode(
          additionalCurrencies.map((code) => code.toUpperCase()).toList(),
        ),
        'country_code': countryCode.toUpperCase(),
        'city': city?.trim(),
        'address': address?.trim(),
        'contact_phone': contactPhoneDisplay?.trim(),
        'timezone': 'Asia/Aden',
        'is_active': 1,
        'created_at': now,
      };

      final db = await AppDatabase.instance.database;
      await db.transaction((txn) async {
        await txn.insert(
          'local_businesses',
          bizData,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        await txn.insert('offline_mutations_queue', {
          'client_request_id': clientRequestId,
          'command_type': RpcContract.cmdCreateBusiness,
          'payload_json': jsonEncode({
            'p_name': name.trim(),
            'p_business_type': businessType.trim(),
            'p_currency_code': currencyCode.toUpperCase(),
            'p_additional_currencies': additionalCurrencies
                .map((code) => code.toUpperCase())
                .toList(),
            'p_country_code': countryCode.toUpperCase(),
            'p_city': city?.trim(),
            'p_address': address?.trim(),
          }),
          'local_ref_id': localBizId,
          'status': 'pending',
          'created_at': now,
          'attempt_count': 0,
        });
      });

      SyncEngine.instance.triggerSync();
      return bizData;
    }
  }

  /// تحديث العملات الإضافية عبر أمر خادمي يمنع تعطيل عملة مستخدمة في قيود.
  Future<List<String>> updateBusinessCurrencies({
    required String businessId,
    required List<String> additionalCurrencies,
  }) async {
    try {
      final result = await Supabase.instance.client.rpc(
        RpcContract.updateBusinessCurrencies,
        params: {
          'p_business_id': businessId,
          'p_additional_currencies': additionalCurrencies
              .map((code) => code.toUpperCase())
              .toList(),
        },
      );
      final saved = (result as List<dynamic>)
          .map((value) => value.toString().toUpperCase())
          .toList();
      final db = await AppDatabase.instance.database;
      await db.update(
        'local_businesses',
        {'additional_currencies': jsonEncode(saved)},
        where: 'id = ?',
        whereArgs: [businessId],
      );
      return saved;
    } catch (e) {
      throw MerchantApiException.from(e);
    }
  }

  Future<void> updateBusinessLogo({
    required String businessId,
    required Uint8List bytes,
    required String extension,
  }) async {
    if (bytes.isEmpty || bytes.length > 5 * 1024 * 1024) {
      throw const MerchantApiException(
        code: 'invalid_logo_size',
        message: 'يجب أن يكون الشعار صورة صالحة وحجمه أقل من 5 ميجابايت.',
      );
    }
    final safeExtension =
        {'jpg', 'jpeg', 'png', 'webp'}.contains(extension.toLowerCase())
        ? extension.toLowerCase()
        : 'jpg';
    final objectPath = '$businessId/logo.$safeExtension';
    final contentType = safeExtension == 'png'
        ? 'image/png'
        : safeExtension == 'webp'
        ? 'image/webp'
        : 'image/jpeg';
    try {
      final client = Supabase.instance.client;
      await client.storage
          .from('business-assets')
          .uploadBinary(
            objectPath,
            bytes,
            fileOptions: FileOptions(upsert: true, contentType: contentType),
          );
      await client
          .from('businesses')
          .update({'logo_path': objectPath})
          .eq('id', businessId);
      final db = await AppDatabase.instance.database;
      await db.update(
        'local_businesses',
        {'logo_path': objectPath},
        where: 'id = ?',
        whereArgs: [businessId],
      );
    } catch (e) {
      throw MerchantApiException.from(e);
    }
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
    SyncEngine.instance.triggerSync();
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
    final trimmedPhone = rawPhone.isNotEmpty
        ? (rawPhone.startsWith('+')
              ? rawPhone
              : (rawPhone.startsWith('967') ? '+$rawPhone' : '+967$rawPhone'))
        : '';
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
      if (creditLimit != null) 'creditLimit': creditLimit,
      if (defaultDueDays != null) 'defaultDueDays': defaultDueDays,
      'requestLink': trimmedPhone.isNotEmpty,
      'localCustomerId': localId,
    };
    final db = await AppDatabase.instance.database;
    await db.transaction((txn) async {
      await txn.insert(
        'local_business_customers',
        customer.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await txn.insert('offline_mutations_queue', {
        'client_request_id': _uuid.v4(),
        'command_type': RpcContract.cmdCustomerDirectory,
        'payload_json': jsonEncode(payload),
        'local_ref_id': localId,
        'status': 'pending',
        'attempt_count': 0,
        'created_at': now,
      });
    });
    SyncEngine.instance.triggerSync();
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
          if (serverCustomerId != null) 'customer_id': serverCustomerId,
          if (linkStatus != null) 'link_status': linkStatus,
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
  Future<LedgerEntryModel> createLedgerEntry({
    required String businessId,
    required String businessCustomerId,
    required String entryType, // 'debt' or 'payment'
    required double amount,
    required String description,
    String currencyCode = 'YER',
    String category = 'goods',
    String paymentMethod = 'cash',
    String? referenceNumber,
    String? bankOrAgentName,
    String? attachmentPath,
    String? dueDate,
    String? externalReference,
  }) async {
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
    );

    // إطلاق محرك المزامنة في الخلفية
    SyncEngine.instance.triggerSync();

    return entry;
  }

  /// تطبيق خصم للعميل (Discount) — بلا معامل عملة (الخصم بعملة المحل حصراً)
  Future<LedgerEntryModel> applyCustomerDiscount({
    required String businessId,
    required String businessCustomerId,
    required double amount,
    required String description,
    String currencyCode = 'YER',
  }) async {
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

    SyncEngine.instance.triggerSync();

    return entry;
  }

  Future<LedgerEntryModel> applyDiscount({
    required String businessId,
    required String businessCustomerId,
    required double amount,
    required String description,
    String currencyCode = 'YER',
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
    String currencyCode = 'YER',
  }) async {
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
    );

    SyncEngine.instance.triggerSync();

    return entry;
  }

  // ==================== عمليات الاعتراضات والنزاعات (Disputes) ====================

  /// جلب كافة الاعتراضات الخاصة بالمحل.
  ///
  /// التضمين المصحح (خطة 06 خطوة 3.3): لا يوجد FK باسم `profiles!customer_id`؛
  /// اسم العميل يُقرأ من المسار المتداخل ledger_entries→business_customers،
  /// و`global_code` من customers (الهاتف مشفر خلفياً ولا يُعرض).
  /// السقوط إلى الكاش المحلي يحدث عند انقطاع الشبكة فقط — أخطاء العقد تُرمى.
  Future<List<DisputeModel>> getDisputes(String businessId) async {
    try {
      final client = Supabase.instance.client;
      final res = await client
          .from('disputes')
          .select('''
            id, entry_id, business_id, customer_id, reason, description, created_at,
            dispute_state (status, resolution_note, resolved_at),
            ledger_entries (amount, currency_code, entry_type, description, occurred_at,
                            business_customers (local_display_name)),
            customers (global_code)
          ''')
          .eq('business_id', businessId)
          .order('created_at', ascending: false);

      final disputes = (res as List)
          .map((row) => DisputeModel.fromMap(row))
          .toList();

      final db = await AppDatabase.instance.database;
      for (final d in disputes) {
        await db.insert(
          'local_disputes',
          d.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }

      return disputes;
    } catch (e) {
      if (MerchantApiException.isNetworkError(e)) {
        return _getLocalDisputes(businessId);
      }
      throw MerchantApiException.from(e);
    }
  }

  Future<List<DisputeModel>> _getLocalDisputes(String businessId) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query(
      'local_disputes',
      where: 'business_id = ?',
      whereArgs: [businessId],
      orderBy: 'created_at DESC',
    );
    return rows.map((e) => DisputeModel.fromMap(e)).toList();
  }

  /// محادثة النزاع (خطة 06 خطوة 3.4): العمود الفعلي `sender_user_id`
  /// (وليس `sender_id` الشبح)، وبلا تضمين profiles (لا FK وسياسة
  /// profiles_select_own تمنع قراءة الآخرين). تسمية المرسل تُشتق في العميل.
  Future<List<DisputeMessageModel>> getDisputeMessages(String disputeId) async {
    final client = Supabase.instance.client;
    try {
      final res = await client
          .from('dispute_messages')
          .select('id, dispute_id, sender_user_id, message, created_at')
          .eq('dispute_id', disputeId)
          .order('created_at', ascending: true);

      final currentUserId = client.auth.currentUser?.id;
      return (res as List)
          .map(
            (r) => DisputeMessageModel.fromMap(r, currentUserId: currentUserId),
          )
          .toList();
    } catch (e) {
      if (MerchantApiException.isNetworkError(e)) return const [];
      throw MerchantApiException.from(e);
    }
  }

  /// رسالة نزاع — RPC `add_dispute_message` (تصحيح الاسم الشبح command_*).
  /// أونلاين فقط في v1 (خطة 02 §2.1)؛ الفشل يُرمى برسالته الحقيقية ولا يُبتلع.
  Future<bool> addDisputeMessage(String disputeId, String message) async {
    try {
      final client = Supabase.instance.client;
      await client.rpc(
        RpcContract.addDisputeMessage,
        params: {'p_dispute_id': disputeId, 'p_message': message.trim()},
      );
      return true;
    } catch (e) {
      throw MerchantApiException.from(e);
    }
  }

  /// حل نزاع — RPC `resolve_dispute` مع `p_resolution_note`
  /// (تصحيح الاسم + p_note → p_resolution_note، خطة 06 خطوة 3.2).
  Future<bool> resolveDispute({
    required String disputeId,
    required String resolution,
    required String note,
    double? correctedAmount,
  }) async {
    try {
      final client = Supabase.instance.client;
      await client.rpc(
        RpcContract.resolveDispute,
        params: {
          'p_dispute_id': disputeId,
          'p_resolution': resolution,
          'p_resolution_note': note.trim(),
          'p_corrected_amount': correctedAmount,
        },
      );
      return true;
    } catch (e) {
      throw MerchantApiException.from(e);
    }
  }

  // ==================== عمليات فريق العمل (Team) ====================

  /// قائمة الفريق بالأعمدة الفعلية (خطة 06 خطوة 3.5):
  /// `role, status` (وليس member_role/permissions/is_active الشبحية)،
  /// وبلا تضمين profiles. عرض الأسماء الكاملة ينتظر View خلفية (اعتمادية B-1).
  Future<List<MemberModel>> getMembers(String businessId) async {
    try {
      final client = Supabase.instance.client;
      final res = await client
          .from('business_members')
          .select('id, business_id, user_id, role, status, created_at')
          .eq('business_id', businessId)
          .order('created_at', ascending: true);

      return (res as List).map((row) => MemberModel.fromMap(row)).toList();
    } catch (e) {
      if (MerchantApiException.isNetworkError(e)) return const [];
      throw MerchantApiException.from(e);
    }
  }

  Future<List<MemberInviteModel>> getMemberInvites(String businessId) async {
    try {
      final client = Supabase.instance.client;
      final res = await client
          .from('business_member_invites')
          .select()
          .eq('business_id', businessId)
          .order('created_at', ascending: false);

      return (res as List)
          .map((row) => MemberInviteModel.fromMap(row))
          .toList();
    } catch (e) {
      if (MerchantApiException.isNetworkError(e)) return const [];
      throw MerchantApiException.from(e);
    }
  }

  /// دعوة عضو بالهاتف. يحل الخادم الهاتف إلى مستخدم مسجل من دون كشف أي
  /// بيانات تعريفية، ثم ينفذ RPC الدعوة بصلاحيات المستخدم الحالي.
  Future<bool> inviteMember({
    required String businessId,
    String? targetUserId,
    String? phone,
    required String role,
  }) async {
    final normalizedPhone = phone?.trim() ?? '';
    final target = targetUserId?.trim() ?? '';
    if (normalizedPhone.isEmpty && !_uuidRegex.hasMatch(target)) {
      throw const MerchantApiException(
        code: 'invalid_invitee',
        message: 'أدخل رقم هاتف الموظف بصيغة صحيحة أو معرّف مستخدم صالح.',
      );
    }

    try {
      final client = Supabase.instance.client;
      await client.functions.invoke(
        RpcContract.edgeMemberInvite,
        body: {
          'businessId': businessId,
          'role': role,
          if (normalizedPhone.isNotEmpty) 'phone': normalizedPhone,
          if (normalizedPhone.isEmpty) 'targetUserId': target,
        },
      );
      return true;
    } catch (e) {
      throw MerchantApiException.from(e);
    }
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
    try {
      final codes = currencyCodes
          .map((code) => code.trim().toUpperCase())
          .where((code) => code.length == 3)
          .toSet()
          .toList();
      if (codes.isEmpty) return null;

      final statements = <StatementModel>[];
      for (final code in codes) {
        final statement = await generateCustomerStatement(
          businessCustomerId: businessCustomerId,
          periodFrom: periodFrom,
          periodTo: periodTo,
          currencyCode: code,
        );
        if (statement != null) statements.add(statement);
      }
      if (statements.isEmpty) return null;
      if (statements.length == 1) return statements.first;
      // عند غياب الشبكة تكون التقارير المحلية قد أُنشئت وطُلب توثيقها في
      // الطابور. لا نحاول جمع معرّفاتها المحلية على الخادم.
      if (statements.any((item) => item.downloadUrl == null)) {
        return statements.first;
      }

      final response = await Supabase.instance.client.functions.invoke(
        'combine-statements',
        body: {'statementIds': statements.map((item) => item.id).toList()},
      );
      final data = response.data is Map
          ? Map<String, dynamic>.from(response.data as Map)
          : <String, dynamic>{};
      final rawUrl = data['signedUrl']?.toString();
      if (rawUrl == null || rawUrl.isEmpty) {
        throw const MerchantApiException(
          code: 'pdf_combination_failed',
          message: 'تعذر جمع تقارير العملات في ملف واحد.',
        );
      }
      final signedUri = Uri.parse(rawUrl);
      final apiUri = Uri.parse(SupabaseConfig.effectiveUrl);
      final publicUrl = signedUri
          .replace(
            scheme: apiUri.scheme,
            host: apiUri.host,
            port: apiUri.hasPort ? apiUri.port : null,
          )
          .toString();
      return statements.first.copyWith(downloadUrl: publicUrl);
    } catch (e) {
      throw MerchantApiException.from(e);
    }
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
    try {
      final client = Supabase.instance.client;
      final res = await client.rpc(
        RpcContract.createStatement,
        params: {
          'p_scope': 'business_customer',
          'p_business_customer_id': businessCustomerId,
          'p_period_from': periodFrom,
          'p_period_to': periodTo,
          'p_currency_code': currencyCode?.toUpperCase(),
        },
      );

      final pdfResponse = await client.functions.invoke(
        'generate-statement',
        body: {'statementId': res},
      );
      final pdfData = pdfResponse.data is Map
          ? Map<String, dynamic>.from(pdfResponse.data as Map)
          : <String, dynamic>{};
      if (pdfData['signedUrl'] == null) {
        throw const MerchantApiException(
          code: 'pdf_generation_failed',
          message: 'تعذر إنشاء ملف PDF. حاول مرة أخرى.',
        );
      }
      final refreshedStatement = await client
          .from('statements')
          .select()
          .eq('id', res)
          .single();
      final signedUri = Uri.parse(pdfData['signedUrl'].toString());
      final apiUri = Uri.parse(SupabaseConfig.effectiveUrl);
      final publicDownloadUrl = signedUri
          .replace(
            scheme: apiUri.scheme,
            host: apiUri.host,
            port: apiUri.hasPort ? apiUri.port : null,
          )
          .toString();
      return StatementModel.fromMap(
        refreshedStatement,
        downloadUrl: publicDownloadUrl,
      );
    } catch (e) {
      if (MerchantApiException.isNetworkError(e)) {
        return _generateLocalStatement(
          businessCustomerId: businessCustomerId,
          periodFrom: periodFrom,
          periodTo: periodTo,
          currencyCode: currencyCode,
        );
      }
      throw MerchantApiException.from(e);
    }
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

    double opening = 0;
    double debits = 0;
    double credits = 0;
    for (final row in rows) {
      final entry = LedgerEntryModel.fromMap(row);
      if (entry.isReversed) continue;
      final occurredAt = DateTime.tryParse(entry.occurredAt);
      if (occurredAt == null || occurredAt.isAfter(to)) continue;
      final signed = entry.direction == 'credit' ? -entry.amount : entry.amount;
      if (occurredAt.isBefore(from)) {
        opening += signed;
      } else if (entry.direction == 'credit') {
        credits += entry.amount;
      } else {
        debits += entry.amount;
      }
    }

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
    SyncEngine.instance.triggerSync();

    return StatementModel(
      id: localId,
      scope: 'business_customer',
      businessCustomerId: businessCustomerId,
      periodFrom: periodFrom,
      periodTo: periodTo,
      currencyCode: code,
      openingBalance: opening,
      totalDebits: debits,
      totalCredits: credits,
      closingBalance: opening + debits - credits,
      verificationCode: 'LOCAL-PENDING',
      createdAt: DateTime.now().toIso8601String(),
    );
  }
}
