import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../finance/currency_info.dart';
import '../finance/money.dart';

dynamic replaceReconciledIdDeep(
  dynamic value,
  String localId,
  String serverId,
) {
  if (value is String) return value == localId ? serverId : value;
  if (value is Map) {
    return value.map(
      (key, child) =>
          MapEntry(key, replaceReconciledIdDeep(child, localId, serverId)),
    );
  }
  if (value is List) {
    return value
        .map((child) => replaceReconciledIdDeep(child, localId, serverId))
        .toList();
  }
  return value;
}

/// قاعدة البيانات المحلية السريعة (SQLite Offline Cache Engine)
///
/// الإصدار 3: دورة حياة طابور المزامنة (pending/syncing/failed/dead_letter)،
/// جدول تسوية المعرّفات local_id_map، نقاط تحقق السحب التزايدي،
/// وحارس ضد الحذف الصامت للطابور عند تسجيل الخروج.
class AppDatabase {
  AppDatabase._();
  static final AppDatabase instance = AppDatabase._();

  static const String _dbName = 'muthbat_offline_ledger.db';
  static const int _dbVersion = 7;

  static const _uuid = Uuid();

  Database? _database;
  String? _accountId;
  String? get accountId => _accountId;
  static const _rememberedOwnerKey = 'remembered_local_owner_v1';
  static const _rememberedCustomerKey = 'remembered_local_customer_v1';

  /// Local device access only. A cached profile is never a server credential.
  Future<void> rememberCustomer() async {
    final id = _accountId;
    if (id == null || await getProfile(id) == null) return;
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(_rememberedCustomerKey, id)) {
      throw StateError('Unable to persist local customer preference');
    }
  }

  Future<Map<String, dynamic>?> restoreRememberedCustomer() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_rememberedCustomerKey);
    if (id == null) return null;
    await bindAccount(id);
    final profile = await getProfile(id);
    if (profile == null) {
      await lockAccount();
      return null;
    }
    return profile;
  }

  /// Local access preference only: never used as a JWT or server credential.
  Future<void> rememberOwner() async {
    final id = _accountId;
    if (id == null || await getBusinessByOwnerId(id) == null) return;
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(_rememberedOwnerKey, id)) {
      throw StateError('Unable to persist local owner preference');
    }
  }

  Future<Map<String, dynamic>?> restoreRememberedOwner() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_rememberedOwnerKey);
    if (id == null) return null;
    await bindAccount(id);
    final business = await getBusinessByOwnerId(id);
    if (business == null) {
      await lockAccount();
      return null;
    }
    return business;
  }

  Future<void> forgetRememberedOwner() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_rememberedOwnerKey);
    await prefs.remove(_rememberedCustomerKey);
  }

  /// Call only after draining SyncEngine. Legacy storage is copied (not moved)
  /// only when its single cached profile establishes the account owner.
  Future<void> bindAccount(String userId) async {
    if (!RegExp(r'^[a-fA-F0-9-]{36}$').hasMatch(userId)) {
      throw ArgumentError('Invalid account id');
    }
    if (_accountId == userId) return;
    await _database?.close();
    _database = null;
    _accountId = null;
    final directory = await getDatabasesPath();
    final target = join(directory, 'muthbat_account_$userId.db');
    final legacy = join(directory, _dbName);
    if (!await File(target).exists() && await File(legacy).exists()) {
      final old = await openDatabase(legacy, readOnly: true);
      bool belongsToUser = false;
      try {
        final profiles = await old.query('local_profiles', columns: ['id']);
        belongsToUser = profiles.length == 1 && profiles.single['id'] == userId;
      } finally {
        await old.close();
      }
      if (belongsToUser) await File(legacy).copy(target);
    }
    _accountId = userId;
    await database;
  }

  Future<void> lockAccount() async {
    await _database?.close();
    _database = null;
    _accountId = null;
  }

  Future<Database> get database async {
    if (_accountId == null) throw StateError('Account storage is locked');
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(
      dbPath,
      _accountId == null ? _dbName : 'muthbat_account_$_accountId.db',
    );

    return await openDatabase(
      path,
      version: _dbVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
    );
  }

  // ==================== الترحيلات المنهجية (Migrations) ====================

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await _migrateToV2(db);
    }
    if (oldVersion < 3) {
      await _migrateToV3(db);
    }
    if (oldVersion < 4) {
      await _migrateToV4(db);
    }
    if (oldVersion < 5) {
      await _migrateToV5(db);
    }
    if (oldVersion < 6) {
      await _migrateToV6(db);
    }
    if (oldVersion < 7) {
      await _migrateToV7(db);
    }
  }

  Future<bool> _columnExists(
    DatabaseExecutor db,
    String table,
    String column,
  ) async {
    final rows = await db.rawQuery('PRAGMA table_info($table)');
    return rows.any((r) => r['name'] == column);
  }

  Future<void> _addColumnIfMissing(
    DatabaseExecutor db,
    String table,
    String column,
    String columnDef,
  ) async {
    if (!await _columnExists(db, table, column)) {
      await db.execute('ALTER TABLE $table ADD COLUMN $columnDef');
    }
  }

  /// الترقية إلى v2: أرصدة العملات + أعمدة التصنيف والسداد للقيود.
  Future<void> _migrateToV2(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS local_customer_currency_balances (
        id TEXT PRIMARY KEY,
        business_id TEXT NOT NULL,
        business_customer_id TEXT NOT NULL,
        currency_code TEXT NOT NULL,
        current_balance REAL DEFAULT 0.0,
        total_debits REAL DEFAULT 0.0,
        total_credits REAL DEFAULT 0.0,
        entry_count INTEGER DEFAULT 0,
        last_entry_at TEXT,
        updated_at TEXT,
        UNIQUE(business_customer_id, currency_code)
      )
    ''');

    await _addColumnIfMissing(
      db,
      'local_ledger_entries',
      'category',
      'category TEXT DEFAULT "goods"',
    );
    await _addColumnIfMissing(
      db,
      'local_ledger_entries',
      'payment_method',
      'payment_method TEXT DEFAULT "cash"',
    );
    await _addColumnIfMissing(
      db,
      'local_ledger_entries',
      'reference_number',
      'reference_number TEXT',
    );
    await _addColumnIfMissing(
      db,
      'local_ledger_entries',
      'bank_or_agent_name',
      'bank_or_agent_name TEXT',
    );
    await _addColumnIfMissing(
      db,
      'local_ledger_entries',
      'attachment_path',
      'attachment_path TEXT',
    );
  }

  /// الترقية إلى v3: دورة حياة الطابور + تسوية المعرّفات + نقاط التحقق.
  Future<void> _migrateToV3(Database db) async {
    // 1. أعمدة دورة حياة الطابور
    await _addColumnIfMissing(
      db,
      'offline_mutations_queue',
      'status',
      "status TEXT NOT NULL DEFAULT 'pending'",
    );
    await _addColumnIfMissing(
      db,
      'offline_mutations_queue',
      'next_retry_at',
      'next_retry_at TEXT',
    );
    await _addColumnIfMissing(
      db,
      'offline_mutations_queue',
      'last_error_code',
      'last_error_code TEXT',
    );
    await _addColumnIfMissing(
      db,
      'offline_mutations_queue',
      'server_entity_id',
      'server_entity_id TEXT',
    );
    await _addColumnIfMissing(
      db,
      'offline_mutations_queue',
      'local_ref_id',
      'local_ref_id TEXT',
    );
    await _addColumnIfMissing(
      db,
      'offline_mutations_queue',
      'depends_on_client_request_id',
      'depends_on_client_request_id TEXT',
    );

    // العناصر القديمة (قبل دورة الحياة) تعود إلى pending لتُعاد جدولتها
    await db.rawUpdate(
      "UPDATE offline_mutations_queue SET status = 'pending' WHERE status IS NULL OR status = ''",
    );

    // 2. جدول تسوية المعرّفات المحلية مع معرّفات السيرفر
    await db.execute('''
      CREATE TABLE IF NOT EXISTS local_id_map (
        local_id TEXT PRIMARY KEY,
        server_id TEXT NOT NULL,
        entity_type TEXT NOT NULL,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_local_id_map_server ON local_id_map(server_id)',
    );

    // 3. نقاط تحقق السحب التزايدي (مرآة محلية لـ public.sync_checkpoints)
    await db.execute('''
      CREATE TABLE IF NOT EXISTS local_sync_checkpoints (
        business_id TEXT PRIMARY KEY,
        cursor_value TEXT,
        updated_at TEXT
      )
    ''');

    // 4. حالة المزامنة العامة (مثل معرّف الجهاز الثابت)
    await db.execute('''
      CREATE TABLE IF NOT EXISTS local_sync_state (
        key TEXT PRIMARY KEY,
        value TEXT
      )
    ''');

    // 5. رصيد السيرفر المنفصل (حماية الدلتا التفاؤلية من الكتابة الفوقية)
    await _addColumnIfMissing(
      db,
      'local_business_customers',
      'server_balance',
      'server_balance REAL',
    );
    await _addColumnIfMissing(
      db,
      'local_business_customers',
      'overdue_balance',
      'overdue_balance REAL DEFAULT 0.0',
    );
    await _addColumnIfMissing(
      db,
      'local_businesses',
      'additional_currencies',
      'additional_currencies TEXT DEFAULT \'[]\'',
    );
  }

  Future<void> _migrateToV4(Database db) async {
    await _addColumnIfMissing(
      db,
      'local_businesses',
      'additional_currencies',
      "additional_currencies TEXT DEFAULT '[]'",
    );
  }

  Future<void> _migrateToV5(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS local_currencies (
        code TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        symbol TEXT NOT NULL,
        decimal_scale INTEGER NOT NULL DEFAULT 4,
        is_active INTEGER NOT NULL DEFAULT 1,
        updated_at TEXT
      )
    ''');
    await _addColumnIfMissing(
      db,
      'local_ledger_entries',
      'amount_minor',
      'amount_minor INTEGER',
    );
    await _addColumnIfMissing(
      db,
      'local_customer_currency_balances',
      'current_balance_minor',
      'current_balance_minor INTEGER DEFAULT 0',
    );
    await _addColumnIfMissing(
      db,
      'local_customer_currency_balances',
      'total_debits_minor',
      'total_debits_minor INTEGER DEFAULT 0',
    );
    await _addColumnIfMissing(
      db,
      'local_customer_currency_balances',
      'total_credits_minor',
      'total_credits_minor INTEGER DEFAULT 0',
    );
    await db.transaction((txn) async {
      for (final currency in CurrencyCatalog.defaults) {
        await txn.insert(
          'local_currencies',
          currency.toMap(),
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
      final entries = await txn.query('local_ledger_entries');
      for (final row in entries) {
        final amount = (row['amount'] as num?)?.toDouble();
        if (amount != null) {
          await txn.update(
            'local_ledger_entries',
            {'amount_minor': Money.fromNum(amount).minorUnits},
            where: 'id = ?',
            whereArgs: [row['id']],
          );
        }
      }
    });
  }

  Future<void> _migrateToV7(Database db) async {
    await _addColumnIfMissing(
      db,
      'local_businesses',
      'address',
      'address TEXT',
    );
    await _addColumnIfMissing(
      db,
      'local_businesses',
      'logo_path',
      'logo_path TEXT',
    );
    await _addColumnIfMissing(
      db,
      'local_businesses',
      'timezone',
      "timezone TEXT DEFAULT 'Asia/Aden'",
    );
  }

  /// v6: repair databases created by builds that shipped the column in the
  /// model but did not bump the SQLite schema version.
  Future<void> _migrateToV6(Database db) async {
    await _addColumnIfMissing(
      db,
      'local_business_customers',
      'overdue_balance',
      'overdue_balance REAL DEFAULT 0.0',
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    // 1. جدول الملف الشخصي المحلي
    await db.execute('''
      CREATE TABLE local_profiles (
        id TEXT PRIMARY KEY,
        display_name TEXT NOT NULL,
        avatar_path TEXT,
        city TEXT,
        preferred_language TEXT DEFAULT 'ar',
        user_type TEXT DEFAULT 'merchant',
        phone TEXT,
        created_at TEXT,
        updated_at TEXT
      )
    ''');

    // 2. جدول المحلات المحلية
    await db.execute('''
      CREATE TABLE local_businesses (
        id TEXT PRIMARY KEY,
        owner_user_id TEXT NOT NULL,
        name TEXT NOT NULL,
        business_type TEXT,
        currency_code TEXT DEFAULT 'YER',
        additional_currencies TEXT DEFAULT '[]',
        country_code TEXT DEFAULT 'YE',
        city TEXT,
        address TEXT,
        contact_phone TEXT,
        logo_path TEXT,
        timezone TEXT DEFAULT 'Asia/Aden',
        is_active INTEGER DEFAULT 1,
        created_at TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE local_currencies (
        code TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        symbol TEXT NOT NULL,
        decimal_scale INTEGER NOT NULL DEFAULT 4,
        is_active INTEGER NOT NULL DEFAULT 1,
        updated_at TEXT
      )
    ''');
    for (final currency in CurrencyCatalog.defaults) {
      await db.insert('local_currencies', currency.toMap());
    }

    // 3. جدول عملاء المحل المحليين
    await db.execute('''
      CREATE TABLE local_business_customers (
        id TEXT PRIMARY KEY,
        business_id TEXT NOT NULL,
        customer_id TEXT,
        local_display_name TEXT NOT NULL,
        local_note TEXT,
        phone TEXT,
        credit_limit REAL,
        default_due_days INTEGER,
        link_status TEXT DEFAULT 'unlinked',
        current_balance REAL DEFAULT 0.0,
        amount_customer_owes REAL DEFAULT 0.0,
        amount_business_owes_customer REAL DEFAULT 0.0,
        overdue_balance REAL DEFAULT 0.0,
        server_balance REAL,
        is_archived INTEGER DEFAULT 0,
        sync_status TEXT DEFAULT 'synced',
        created_at TEXT,
        updated_at TEXT
      )
    ''');

    // 4. جدول القيود والديون المالية المحلية
    await db.execute('''
      CREATE TABLE local_ledger_entries (
        id TEXT PRIMARY KEY,
        business_id TEXT NOT NULL,
        business_customer_id TEXT NOT NULL,
        customer_id TEXT,
        entry_type TEXT NOT NULL,
        direction TEXT NOT NULL,
        amount REAL NOT NULL,
        amount_minor INTEGER,
        currency_code TEXT DEFAULT 'YER',
        category TEXT DEFAULT 'goods',
        payment_method TEXT DEFAULT 'cash',
        reference_number TEXT,
        bank_or_agent_name TEXT,
        attachment_path TEXT,
        description TEXT NOT NULL,
        occurred_at TEXT NOT NULL,
        due_date TEXT,
        external_reference TEXT,
        client_request_id TEXT UNIQUE NOT NULL,
        confirmation_status TEXT DEFAULT 'not_available',
        dispute_status TEXT DEFAULT 'none',
        is_reversed INTEGER DEFAULT 0,
        sync_status TEXT DEFAULT 'synced',
        created_at TEXT
      )
    ''');

    // 5. جدول أرصدة العملاء متعددة العملات
    await db.execute('''
      CREATE TABLE local_customer_currency_balances (
        id TEXT PRIMARY KEY,
        business_id TEXT NOT NULL,
        business_customer_id TEXT NOT NULL,
        currency_code TEXT NOT NULL,
        current_balance REAL DEFAULT 0.0,
        current_balance_minor INTEGER DEFAULT 0,
        total_debits REAL DEFAULT 0.0,
        total_debits_minor INTEGER DEFAULT 0,
        total_credits REAL DEFAULT 0.0,
        total_credits_minor INTEGER DEFAULT 0,
        entry_count INTEGER DEFAULT 0,
        last_entry_at TEXT,
        updated_at TEXT,
        UNIQUE(business_customer_id, currency_code)
      )
    ''');

    // 6. جدول طابور الأوامر غير المتصلة (Offline Mutation Queue) بدورة حياة كاملة
    await db.execute('''
      CREATE TABLE offline_mutations_queue (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        client_request_id TEXT UNIQUE NOT NULL,
        command_type TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        local_ref_id TEXT,
        status TEXT NOT NULL DEFAULT 'pending',
        attempt_count INTEGER DEFAULT 0,
        next_retry_at TEXT,
        last_error TEXT,
        last_error_code TEXT,
        server_entity_id TEXT,
        depends_on_client_request_id TEXT,
        created_at TEXT NOT NULL
      )
    ''');

    // 7. جدول النزاعات المحلية
    await db.execute('''
      CREATE TABLE local_disputes (
        id TEXT PRIMARY KEY,
        entry_id TEXT NOT NULL,
        business_id TEXT NOT NULL,
        customer_id TEXT NOT NULL,
        reason TEXT NOT NULL,
        description TEXT NOT NULL,
        status TEXT DEFAULT 'open',
        resolution_note TEXT,
        created_at TEXT
      )
    ''');

    // 8. جدول تسوية المعرّفات المحلية مع معرّفات السيرفر
    await db.execute('''
      CREATE TABLE local_id_map (
        local_id TEXT PRIMARY KEY,
        server_id TEXT NOT NULL,
        entity_type TEXT NOT NULL,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_local_id_map_server ON local_id_map(server_id)',
    );

    // 9. نقاط تحقق السحب التزايدي (مرآة محلية لـ public.sync_checkpoints)
    await db.execute('''
      CREATE TABLE local_sync_checkpoints (
        business_id TEXT PRIMARY KEY,
        cursor_value TEXT,
        updated_at TEXT
      )
    ''');

    // 10. حالة المزامنة العامة (مثل معرّف الجهاز الثابت)
    await db.execute('''
      CREATE TABLE local_sync_state (
        key TEXT PRIMARY KEY,
        value TEXT
      )
    ''');
  }

  // ==================== عمليات الملف الشخصي والمحل ====================

  Future<void> saveProfile(Map<String, dynamic> profile) async {
    final db = await database;
    await db.insert(
      'local_profiles',
      profile,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Map<String, dynamic>?> getProfile(String userId) async {
    final db = await database;
    final results = await db.query(
      'local_profiles',
      where: 'id = ?',
      whereArgs: [userId],
      limit: 1,
    );
    return results.isNotEmpty ? results.first : null;
  }

  Future<Map<String, dynamic>?> getProfileByPhone(String phone) async {
    final db = await database;
    final results = await db.query(
      'local_profiles',
      where: 'phone = ?',
      whereArgs: [phone],
      limit: 1,
    );
    return results.isNotEmpty ? results.first : null;
  }

  Future<void> saveBusiness(Map<String, dynamic> business) async {
    final db = await database;
    await db.insert(
      'local_businesses',
      business,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await rememberOwner();
  }

  Future<Map<String, dynamic>?> getBusinessByOwnerId(String ownerUserId) async {
    final db = await database;
    final results = await db.query(
      'local_businesses',
      where: 'owner_user_id = ? AND is_active = 1',
      whereArgs: [ownerUserId],
      limit: 1,
    );
    return results.isNotEmpty ? results.first : null;
  }

  Future<Map<String, dynamic>?> getActiveBusiness([String? ownerUserId]) async {
    final db = await database;
    if (ownerUserId != null && ownerUserId.isNotEmpty) {
      final res = await getBusinessByOwnerId(ownerUserId);
      if (res != null) return res;
    }
    final results = await db.query(
      'local_businesses',
      where: 'is_active = 1',
      limit: 1,
    );
    return results.isNotEmpty ? results.first : null;
  }

  // ==================== عمليات العملاء (Customers) ====================

  Future<List<Map<String, dynamic>>> getBusinessCustomers(
    String businessId, {
    String? searchQuery,
  }) async {
    final db = await database;
    String whereClause = 'business_id = ? AND is_archived = 0';
    List<dynamic> whereArgs = [businessId];

    if (searchQuery != null && searchQuery.trim().isNotEmpty) {
      whereClause += ' AND (local_display_name LIKE ? OR phone LIKE ?)';
      final q = '%${searchQuery.trim()}%';
      whereArgs.addAll([q, q]);
    }

    return await db.query(
      'local_business_customers',
      where: whereClause,
      whereArgs: whereArgs,
      orderBy: 'updated_at DESC, local_display_name ASC',
    );
  }

  Future<Map<String, dynamic>?> getCustomerById(String customerId) async {
    final db = await database;
    final results = await db.query(
      'local_business_customers',
      where: 'id = ?',
      whereArgs: [customerId],
      limit: 1,
    );
    return results.isNotEmpty ? results.first : null;
  }

  /// إدراج/تحديث عميل مع حماية السجلات المعلقة من الكتابة الفوقية.
  ///
  /// عند [fromServer] = true وسجل محلي `sync_status` يبدأ بـ `pending`:
  /// لا تُمس الحقول الوصفية (الاسم/الملاحة/الحد) ولا الحالة، ويُخزَّن رصيد
  /// السيرفر في `server_balance` فقط (العرض = رصيد السيرفر + الدلتا التفاؤلية).
  Future<void> upsertBusinessCustomer(
    Map<String, dynamic> customer, {
    bool fromServer = false,
  }) async {
    final db = await database;
    final id = customer['id'] as String?;

    if (fromServer && id != null) {
      final existing = await db.query(
        'local_business_customers',
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );

      if (existing.isNotEmpty) {
        final syncStatus =
            (existing.first['sync_status'] as String?) ?? 'synced';
        if (syncStatus.startsWith('pending')) {
          // حماية السجل المعلق: تحديث الحقول المشتقة من السيرفر فقط
          await db.update(
            'local_business_customers',
            {
              'server_balance':
                  (customer['current_balance'] as num?)?.toDouble() ?? 0.0,
              'link_status':
                  customer['link_status'] ?? existing.first['link_status'],
            },
            where: 'id = ?',
            whereArgs: [id],
          );
          return;
        }
      }

      final row = Map<String, dynamic>.from(customer);
      row['server_balance'] =
          (customer['current_balance'] as num?)?.toDouble() ?? 0.0;
      await db.insert(
        'local_business_customers',
        row,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      return;
    }

    await db.insert(
      'local_business_customers',
      customer,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // ==================== أرصدة العملات المتعددة للعملاء ====================

  Future<Map<String, double>> getCustomerCurrencyBalances(
    String businessCustomerId,
  ) async {
    final db = await database;
    final rows = await db.query(
      'local_customer_currency_balances',
      where: 'business_customer_id = ?',
      whereArgs: [businessCustomerId],
    );

    final Map<String, double> balances = {};
    for (final row in rows) {
      final curr = (row['currency_code'] as String?)?.toUpperCase() ?? 'YER';
      final bal = (row['current_balance'] as num?)?.toDouble() ?? 0.0;
      balances[curr] = bal;
    }
    return balances;
  }

  Future<List<CurrencyInfo>> getCurrencies() async {
    final db = await database;
    final rows = await db.query(
      'local_currencies',
      where: 'is_active = 1',
      orderBy: 'code ASC',
    );
    return rows.map(CurrencyInfo.fromMap).toList();
  }

  Future<void> upsertCurrencies(List<Map<String, dynamic>> rows) async {
    final db = await database;
    await db.transaction((txn) async {
      for (final row in rows) {
        await txn.insert('local_currencies', {
          'code': (row['code'] as String).toUpperCase(),
          'name': row['name'],
          'symbol': row['symbol'],
          'decimal_scale': (row['decimal_scale'] as num?)?.toInt() ?? 4,
          'is_active': row['is_active'] == true || row['is_active'] == 1
              ? 1
              : 0,
          'updated_at': row['updated_at'],
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  Future<List<Map<String, dynamic>>> getAllCurrencyTotalsForBusiness(
    String businessId,
  ) async {
    final db = await database;
    return await db.rawQuery(
      '''
      SELECT 
        currency_code,
        SUM(CASE WHEN current_balance > 0 THEN current_balance ELSE 0 END) as total_receivables,
        SUM(CASE WHEN current_balance < 0 THEN ABS(current_balance) ELSE 0 END) as total_payables,
        COUNT(DISTINCT business_customer_id) as customer_count
      FROM local_customer_currency_balances
      WHERE business_id = ?
      GROUP BY currency_code
    ''',
      [businessId],
    );
  }

  /// كتابة أرصدة العملات القادمة من السيرفر (Server-wins) مع حماية
  /// أرصدة العملاء الذين لديهم قيود تفاؤلية معلقة لم تُزامَن بعد.
  Future<void> upsertCurrencyBalancesFromServer(
    String businessId,
    List<Map<String, dynamic>> rows,
  ) async {
    final db = await database;
    await db.transaction((txn) async {
      for (final row in rows) {
        final custId = row['business_customer_id'] as String?;
        if (custId == null) continue;

        final pending = await txn.rawQuery(
          "SELECT COUNT(*) AS c FROM local_ledger_entries "
          "WHERE business_customer_id = ? AND currency_code = ? AND sync_status LIKE 'pending%'",
          [custId, (row['currency_code'] as String?)?.toUpperCase() ?? 'YER'],
        );
        if ((Sqflite.firstIntValue(pending) ?? 0) > 0) continue;

        final currency =
            (row['currency_code'] as String?)?.toUpperCase() ?? 'YER';
        final serverBalance =
            (row['current_balance'] as num?)?.toDouble() ?? 0.0;
        final serverDebits = (row['total_debits'] as num?)?.toDouble() ?? 0.0;
        final serverCredits = (row['total_credits'] as num?)?.toDouble() ?? 0.0;
        await txn.insert(
          'local_customer_currency_balances',
          {
            'id': 'bal-$custId-$currency',
            'business_id': businessId,
            'business_customer_id': custId,
            'currency_code': currency,
            'current_balance': serverBalance,
            'current_balance_minor': Money.fromNum(serverBalance).minorUnits,
            'total_debits': serverDebits,
            'total_debits_minor': Money.fromNum(serverDebits).minorUnits,
            'total_credits': serverCredits,
            'total_credits_minor': Money.fromNum(serverCredits).minorUnits,
            'entry_count': (row['entry_count'] as num?)?.toInt() ?? 0,
            'last_entry_at': row['last_entry_at'],
            'updated_at': DateTime.now().toIso8601String(),
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  // ==================== عمليات القيود المالية (Ledger Entries) ====================

  Future<List<Map<String, dynamic>>> getLedgerEntries(
    String businessCustomerId, {
    String? currencyCode,
  }) async {
    final db = await database;
    String whereClause = 'business_customer_id = ?';
    List<dynamic> whereArgs = [businessCustomerId];

    if (currencyCode != null && currencyCode.isNotEmpty) {
      whereClause += ' AND currency_code = ?';
      whereArgs.add(currencyCode.toUpperCase());
    }

    return await db.query(
      'local_ledger_entries',
      where: whereClause,
      whereArgs: whereArgs,
      orderBy: 'occurred_at DESC, created_at DESC',
    );
  }

  Future<List<Map<String, dynamic>>> getRecentBusinessLedgerEntries(
    String businessId, {
    int limit = 10,
  }) async {
    final db = await database;
    return db.query(
      'local_ledger_entries',
      where: 'business_id = ?',
      whereArgs: [businessId],
      orderBy: 'occurred_at DESC, created_at DESC',
      limit: limit,
    );
  }

  /// حفظ قيد تفاؤلي + تحديث الأرصدة + إدراج أمر في الطابور (معاملة واحدة).
  Future<void> saveLedgerEntryOptimistic({
    required Map<String, dynamic> entry,
    required String commandType,
    required Map<String, dynamic> payload,
    String? dependsOnClientRequestId,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      // إذا أضيف القيد لعميل محلي جديد، اجعله يعتمد على أمر إنشاء العميل.
      // هذا يمنع سباق إرسال الدين قبل حصول العميل على معرّفه الخادمي.
      String? effectiveDependency = dependsOnClientRequestId;
      if (effectiveDependency == null) {
        final customerId = entry['business_customer_id'] as String?;
        if (customerId != null && customerId.startsWith('cust-')) {
          final parent = await txn.query(
            'offline_mutations_queue',
            columns: ['client_request_id'],
            where:
                "local_ref_id = ? AND command_type IN ('customer_directory', 'add_business_customer', 'pending_directory')",
            whereArgs: [customerId],
            orderBy: 'id DESC',
            limit: 1,
          );
          if (parent.isNotEmpty) {
            effectiveDependency = parent.first['client_request_id'] as String?;
          }
        }
      }
      // 1. حفظ القيد المالي فوراً في الكاش المحلي
      await txn.insert(
        'local_ledger_entries',
        entry,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      final double amount = (entry['amount'] as num).toDouble();
      final money = Money.fromNum(amount);
      final amountMinor = money.minorUnits;
      await txn.update(
        'local_ledger_entries',
        {'amount_minor': amountMinor},
        where: 'id = ?',
        whereArgs: [entry['id']],
      );
      final String entryType = entry['entry_type'] as String;
      final String direction = (entry['direction'] as String?) ?? 'debit';
      final String custId = entry['business_customer_id'] as String;
      final String businessId = entry['business_id'] as String;
      final String currency =
          (entry['currency_code'] as String?)?.toUpperCase() ?? 'YER';
      final businessRows = await txn.query(
        'local_businesses',
        columns: ['currency_code'],
        where: 'id = ?',
        whereArgs: [businessId],
        limit: 1,
      );
      final baseCurrency =
          ((businessRows.isNotEmpty
                          ? businessRows.first['currency_code']
                          : null)
                      as String? ??
                  'YER')
              .toUpperCase();

      // 2. تحديث جدول الأرصدة متعددة العملات (local_customer_currency_balances)
      final existingCurrencyRow = await txn.query(
        'local_customer_currency_balances',
        where: 'business_customer_id = ? AND currency_code = ?',
        whereArgs: [custId, currency],
        limit: 1,
      );

      int currBalMinor = 0;
      int debitsMinor = 0;
      int creditsMinor = 0;
      int count = 0;

      if (existingCurrencyRow.isNotEmpty) {
        currBalMinor =
            (existingCurrencyRow.first['current_balance_minor'] as num?)
                ?.toInt() ??
            Money.fromNum(
              (existingCurrencyRow.first['current_balance'] as num?)
                      ?.toDouble() ??
                  0,
            ).minorUnits;
        debitsMinor =
            (existingCurrencyRow.first['total_debits_minor'] as num?)
                ?.toInt() ??
            Money.fromNum(
              (existingCurrencyRow.first['total_debits'] as num?)?.toDouble() ??
                  0,
            ).minorUnits;
        creditsMinor =
            (existingCurrencyRow.first['total_credits_minor'] as num?)
                ?.toInt() ??
            Money.fromNum(
              (existingCurrencyRow.first['total_credits'] as num?)
                      ?.toDouble() ??
                  0,
            ).minorUnits;
        count =
            (existingCurrencyRow.first['entry_count'] as num?)?.toInt() ?? 0;
      }

      // العكس (reversal) يُعامل حسب اتجاهه: debit يضيف وcredit يطرح
      if (entryType == 'debt' || entryType == 'fee') {
        currBalMinor += amountMinor;
        debitsMinor += amountMinor;
      } else if (entryType == 'payment' || entryType == 'discount') {
        currBalMinor -= amountMinor;
        creditsMinor += amountMinor;
      } else if (entryType == 'reversal') {
        if (direction == 'debit') {
          currBalMinor += amountMinor;
          debitsMinor += amountMinor;
        } else {
          currBalMinor -= amountMinor;
          creditsMinor += amountMinor;
        }
      }

      await txn.insert(
        'local_customer_currency_balances',
        {
          'id': 'bal-$custId-$currency',
          'business_id': businessId,
          'business_customer_id': custId,
          'currency_code': currency,
          'current_balance': Money.fromMinorUnits(currBalMinor).toDouble(),
          'current_balance_minor': currBalMinor,
          'total_debits': Money.fromMinorUnits(debitsMinor).toDouble(),
          'total_debits_minor': debitsMinor,
          'total_credits': Money.fromMinorUnits(creditsMinor).toDouble(),
          'total_credits_minor': creditsMinor,
          'entry_count': count + 1,
          'last_entry_at':
              entry['occurred_at'] ?? DateTime.now().toIso8601String(),
          'updated_at': DateTime.now().toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      // 3. تحديث الرصيد المسطح الافتراضي في جدول العميل (للتوافق القديم)
      final custRows = await txn.query(
        'local_business_customers',
        where: 'id = ?',
        whereArgs: [custId],
        limit: 1,
      );

      if (custRows.isNotEmpty && currency == baseCurrency) {
        int currentBalMinor = Money.fromNum(
          (custRows.first['current_balance'] as num?)?.toDouble() ?? 0,
        ).minorUnits;
        if (entryType == 'debt' || entryType == 'fee') {
          currentBalMinor += amountMinor;
        } else if (entryType == 'payment' || entryType == 'discount') {
          currentBalMinor -= amountMinor;
        } else if (entryType == 'reversal') {
          currentBalMinor += direction == 'debit' ? amountMinor : -amountMinor;
        }

        final currentBal = Money.fromMinorUnits(currentBalMinor).toDouble();
        final double owes = currentBal > 0 ? currentBal : 0.0;
        final double advance = currentBal < 0 ? currentBal.abs() : 0.0;

        await txn.update(
          'local_business_customers',
          {
            'current_balance': currentBal,
            'amount_customer_owes': owes,
            'amount_business_owes_customer': advance,
            'updated_at': DateTime.now().toIso8601String(),
          },
          where: 'id = ?',
          whereArgs: [custId],
        );
      }

      // 4. إضافة الأمر إلى طابور المزامنة
      await txn.insert('offline_mutations_queue', {
        'client_request_id': entry['client_request_id'],
        'command_type': commandType,
        'payload_json': jsonEncode(payload),
        'local_ref_id': entry['id'],
        'status': 'pending',
        'attempt_count': 0,
        'depends_on_client_request_id': effectiveDependency,
        'created_at': DateTime.now().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  /// كتابة قيد قادم من السيرفر (Server-wins، append-only) مع حماية
  /// القيود التفاؤلية المعلقة (نفس client_request_id بحالة pending).
  Future<void> upsertLedgerEntryFromServer(Map<String, dynamic> row) async {
    final db = await database;
    final crid = row['client_request_id'] as String?;

    if (crid != null) {
      final local = await db.query(
        'local_ledger_entries',
        where: 'client_request_id = ?',
        whereArgs: [crid],
        limit: 1,
      );
      if (local.isNotEmpty) {
        final status = (local.first['sync_status'] as String?) ?? '';
        if (status.startsWith('pending')) return; // حماية القيد التفاؤلي
      }
    }

    await db.insert('local_ledger_entries', {
      'id': row['id'],
      'business_id': row['business_id'],
      'business_customer_id': row['business_customer_id'],
      'customer_id': row['customer_id'],
      'entry_type': row['entry_type'],
      'direction': row['direction'],
      'amount': (row['amount'] as num?)?.toDouble() ?? 0.0,
      'amount_minor': Money.fromNum(
        (row['amount'] as num?)?.toDouble() ?? 0.0,
      ).minorUnits,
      'currency_code':
          (row['currency_code'] as String?)?.toUpperCase() ?? 'YER',
      'category': row['category'] ?? 'goods',
      'payment_method': row['payment_method'] ?? 'cash',
      'reference_number': row['reference_number'],
      'bank_or_agent_name': row['bank_or_agent_name'],
      'attachment_path': row['attachment_path'] ?? row['attachment_url'],
      'description': row['description'] ?? '',
      'occurred_at': row['occurred_at'],
      'due_date': row['due_date'],
      'external_reference': row['external_reference'],
      'client_request_id': crid ?? 'srv-${row['id']}',
      'confirmation_status': row['confirmation_status'] ?? 'not_available',
      'dispute_status': row['dispute_status'] ?? 'none',
      'is_reversed': (row['is_reversed'] == true || row['is_reversed'] == 1)
          ? 1
          : 0,
      'sync_status': 'synced',
      'created_at': row['created_at'],
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> markLedgerEntrySynced(String clientRequestId) async {
    final db = await database;
    await db.update(
      'local_ledger_entries',
      {'sync_status': 'synced'},
      where: 'client_request_id = ?',
      whereArgs: [clientRequestId],
    );
  }

  // ==================== النزاعات المحلية (Server-wins) ====================

  Future<void> upsertLocalDispute(Map<String, dynamic> dispute) async {
    final db = await database;
    await db.insert(
      'local_disputes',
      dispute,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // ==================== إدارة طابور المزامنة (Offline Queue) ====================

  /// إدراج أمر عام في الطابور (يستخدمه مزوّد الواجهة لأوامر مثل
  /// تأكيد قيد / فتح نزاع / إضافة عميل عبر customer-directory).
  Future<String> enqueueMutation({
    required String commandType,
    required Map<String, dynamic> payload,
    String? clientRequestId,
    String? localRefId,
    String? dependsOnClientRequestId,
  }) async {
    final db = await database;
    final crid = clientRequestId ?? _uuid.v4();
    await db.insert('offline_mutations_queue', {
      'client_request_id': crid,
      'command_type': commandType,
      'payload_json': jsonEncode(payload),
      'local_ref_id': localRefId,
      'status': 'pending',
      'attempt_count': 0,
      'depends_on_client_request_id': dependsOnClientRequestId,
      'created_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    return crid;
  }

  /// كل عناصر الطابور بالترتيب (للتوافق القديم — المحرك يستخدم getDueMutations).
  Future<List<Map<String, dynamic>>> getPendingMutations() async {
    final db = await database;
    return await db.query('offline_mutations_queue', orderBy: 'id ASC');
  }

  /// العناصر المستحقة للإرسال الآن: pending أو failed انقضت مهلة backoff لها.
  Future<List<Map<String, dynamic>>> getDueMutations(DateTime now) async {
    final db = await database;
    return await db.query(
      'offline_mutations_queue',
      where:
          "status = 'pending' "
          "OR (status = 'failed' AND (next_retry_at IS NULL OR next_retry_at <= ?))",
      whereArgs: [now.toIso8601String()],
      orderBy: 'id ASC',
    );
  }

  /// استرجاع العناصر العالقة في syncing بعد إغلاق مفاجئ للتطبيق.
  Future<void> recoverStuckSyncingMutations() async {
    final db = await database;
    await db.update('offline_mutations_queue', {
      'status': 'pending',
    }, where: "status = 'syncing'");
  }

  Future<void> markMutationSyncing(String clientRequestId) async {
    final db = await database;
    await db.update(
      'offline_mutations_queue',
      {'status': 'syncing'},
      where: 'client_request_id = ?',
      whereArgs: [clientRequestId],
    );
  }

  Future<void> markMutationFailed(
    String clientRequestId, {
    required int attemptCount,
    required String error,
    String? errorCode,
    required DateTime nextRetryAt,
  }) async {
    final db = await database;
    await db.update(
      'offline_mutations_queue',
      {
        'status': 'failed',
        'attempt_count': attemptCount,
        'last_error': error,
        'last_error_code': errorCode,
        'next_retry_at': nextRetryAt.toIso8601String(),
      },
      where: 'client_request_id = ?',
      whereArgs: [clientRequestId],
    );
  }

  /// الفشل الدائم: العنصر لا يُحذف أبداً ويبقى مرئياً للمراجعة اليدوية.
  Future<void> markMutationDeadLetter(
    String clientRequestId, {
    required int attemptCount,
    required String error,
    String? errorCode,
  }) async {
    final db = await database;
    await db.update(
      'offline_mutations_queue',
      {
        'status': 'dead_letter',
        'attempt_count': attemptCount,
        'last_error': error,
        'last_error_code': errorCode,
        'next_retry_at': null,
      },
      where: 'client_request_id = ?',
      whereArgs: [clientRequestId],
    );
  }

  Future<List<Map<String, dynamic>>> getDeadLetterMutations() async {
    final db = await database;
    return await db.query(
      'offline_mutations_queue',
      where: "status = 'dead_letter'",
      orderBy: 'id ASC',
    );
  }

  Future<int> getDeadLetterCount() async {
    final db = await database;
    final result = await db.rawQuery(
      "SELECT COUNT(*) AS count FROM offline_mutations_queue WHERE status = 'dead_letter'",
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  /// إعادة عنصر dead_letter إلى الدورة (تصفير العداد) — بقرار صريح من المستخدم.
  Future<void> retryDeadLetterMutation(String clientRequestId) async {
    final db = await database;
    await db.update(
      'offline_mutations_queue',
      {
        'status': 'pending',
        'attempt_count': 0,
        'next_retry_at': null,
        'last_error': null,
        'last_error_code': null,
      },
      where: 'client_request_id = ?',
      whereArgs: [clientRequestId],
    );
  }

  /// تجاهل وحذف عنصر dead_letter — بقرار صريح من المستخدم (حذف بيانات مالية).
  Future<void> discardDeadLetterMutation(String clientRequestId) async {
    await removeMutation(clientRequestId);
  }

  Future<bool> hasMutation(String clientRequestId) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) AS count FROM offline_mutations_queue WHERE client_request_id = ?',
      [clientRequestId],
    );
    return (Sqflite.firstIntValue(result) ?? 0) > 0;
  }

  Future<void> removeMutation(String clientRequestId) async {
    final db = await database;
    await db.delete(
      'offline_mutations_queue',
      where: 'client_request_id = ?',
      whereArgs: [clientRequestId],
    );
  }

  Future<void> updateMutationAttempt(
    String clientRequestId,
    String error,
  ) async {
    final db = await database;
    await db.rawUpdate(
      '''
      UPDATE offline_mutations_queue 
      SET attempt_count = attempt_count + 1, last_error = ? 
      WHERE client_request_id = ?
    ''',
      [error, clientRequestId],
    );
  }

  /// عدد العناصر النشطة (pending/syncing/failed) — dead_letter لا تُحسب هنا.
  Future<int> getPendingMutationsCount() async {
    final db = await database;
    final result = await db.rawQuery(
      "SELECT COUNT(*) AS count FROM offline_mutations_queue WHERE status != 'dead_letter'",
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  /// عدّادات الطابور مجمعة حسب الحالة (لشريط حالة المزامنة).
  Future<Map<String, int>> getMutationStatusCounts() async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT status, COUNT(*) AS count FROM offline_mutations_queue GROUP BY status',
    );
    final Map<String, int> counts = {};
    for (final row in rows) {
      counts[(row['status'] as String?) ?? 'pending'] =
          (row['count'] as num?)?.toInt() ?? 0;
    }
    return counts;
  }

  // ==================== تسوية المعرّفات (ID Reconciliation) ====================

  Future<void> saveIdMapping({
    required String localId,
    required String serverId,
    required String entityType,
  }) async {
    final db = await database;
    await db.insert('local_id_map', {
      'local_id': localId,
      'server_id': serverId,
      'entity_type': entityType,
      'created_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String?> getServerId(String localId) async {
    final db = await database;
    final rows = await db.query(
      'local_id_map',
      where: 'local_id = ?',
      whereArgs: [localId],
      limit: 1,
    );
    return rows.isNotEmpty ? rows.first['server_id'] as String? : null;
  }

  /// تسوية المنشأة التي أُنشئت دون اتصال. لا يكفي تغيير المفتاح في جدول
  /// المنشآت؛ كل أمر محفوظ بعده قد يحتوي `biz-*` داخل حمولة JSON.
  Future<void> reconcileBusinessId({
    required String localId,
    required String serverId,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.insert('local_id_map', {
        'local_id': localId,
        'server_id': serverId,
        'entity_type': 'business',
        'created_at': DateTime.now().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      final serverRow = await txn.query(
        'local_businesses',
        where: 'id = ?',
        whereArgs: [serverId],
        limit: 1,
      );
      if (serverRow.isEmpty) {
        await txn.update(
          'local_businesses',
          {'id': serverId},
          where: 'id = ?',
          whereArgs: [localId],
        );
      } else {
        await txn.delete(
          'local_businesses',
          where: 'id = ?',
          whereArgs: [localId],
        );
      }
      await txn.update(
        'local_business_customers',
        {'business_id': serverId},
        where: 'business_id = ?',
        whereArgs: [localId],
      );
      await txn.update(
        'local_ledger_entries',
        {'business_id': serverId},
        where: 'business_id = ?',
        whereArgs: [localId],
      );
      await txn.update(
        'local_customer_currency_balances',
        {'business_id': serverId},
        where: 'business_id = ?',
        whereArgs: [localId],
      );
      await txn.update(
        'local_disputes',
        {'business_id': serverId},
        where: 'business_id = ?',
        whereArgs: [localId],
      );
    });
    await _rewritePayloadsForReconciledId(localId, serverId);
  }

  /// تسوية معرّف عميل محلي (cust-*) بمعرّف السيرفر بعد نجاح الإنشاء:
  /// تحديث المفتاح المحلي وكل المراجع + إعادة كتابة حمولات الأوامر المعلقة.
  Future<void> reconcileCustomerId({
    required String localId,
    required String serverId,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.insert('local_id_map', {
        'local_id': localId,
        'server_id': serverId,
        'entity_type': 'business_customer',
        'created_at': DateTime.now().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      final serverRowExists = await txn.query(
        'local_business_customers',
        where: 'id = ?',
        whereArgs: [serverId],
        limit: 1,
      );

      if (serverRowExists.isNotEmpty) {
        // السيرفر سُحب مسبقاً — السيرفر يكسب ويُحذف الصف المحلي المكرر
        await txn.delete(
          'local_business_customers',
          where: 'id = ?',
          whereArgs: [localId],
        );
      } else {
        await txn.update(
          'local_business_customers',
          {'id': serverId, 'sync_status': 'synced'},
          where: 'id = ?',
          whereArgs: [localId],
        );
      }

      await txn.update(
        'local_ledger_entries',
        {'business_customer_id': serverId},
        where: 'business_customer_id = ?',
        whereArgs: [localId],
      );

      final balRows = await txn.query(
        'local_customer_currency_balances',
        where: 'business_customer_id = ?',
        whereArgs: [localId],
      );
      for (final bal in balRows) {
        final currency = (bal['currency_code'] as String?) ?? 'YER';
        await txn.update(
          'local_customer_currency_balances',
          {'id': 'bal-$serverId-$currency', 'business_customer_id': serverId},
          where: 'id = ?',
          whereArgs: [bal['id']],
        );
      }
    });

    await _rewritePayloadsForReconciledId(localId, serverId);
  }

  /// تسوية معرّف قيد محلي (entry-*) بمعرّف السيرفر بعد نجاح الإرسال.
  Future<void> reconcileEntryId({
    required String localId,
    required String serverId,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.insert('local_id_map', {
        'local_id': localId,
        'server_id': serverId,
        'entity_type': 'ledger_entry',
        'created_at': DateTime.now().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      final serverRowExists = await txn.query(
        'local_ledger_entries',
        where: 'id = ?',
        whereArgs: [serverId],
        limit: 1,
      );

      if (serverRowExists.isNotEmpty) {
        await txn.delete(
          'local_ledger_entries',
          where: 'id = ?',
          whereArgs: [localId],
        );
      } else {
        await txn.update(
          'local_ledger_entries',
          {'id': serverId, 'sync_status': 'synced'},
          where: 'id = ?',
          whereArgs: [localId],
        );
      }

      await txn.update(
        'local_disputes',
        {'entry_id': serverId},
        where: 'entry_id = ?',
        whereArgs: [localId],
      );
    });

    await _rewritePayloadsForReconciledId(localId, serverId);
  }

  /// إعادة كتابة المعرّفات المحلية في حمولات الأوامر المعلقة بعد التسوية
  /// (مثلاً p_business_customer_id / p_entry_id للأوامر المعتمدة).
  Future<void> _rewritePayloadsForReconciledId(
    String localId,
    String serverId,
  ) async {
    final db = await database;
    final rows = await db.query('offline_mutations_queue');
    for (final row in rows) {
      final payloadJson = row['payload_json'] as String?;
      if (payloadJson == null || !payloadJson.contains(localId)) continue;

      try {
        final decoded = jsonDecode(payloadJson);
        final rewritten = replaceReconciledIdDeep(decoded, localId, serverId);
        await db.update(
          'offline_mutations_queue',
          {'payload_json': jsonEncode(rewritten)},
          where: 'client_request_id = ?',
          whereArgs: [row['client_request_id']],
        );
      } catch (_) {
        // حمولة تالفة تُترك كما هي — ستُصنَّف dead_letter عند الإرسال
      }
    }
  }

  // ==================== نقاط تحقق السحب التزايدي ====================

  Future<String?> getLocalCheckpoint(String businessId) async {
    final db = await database;
    final rows = await db.query(
      'local_sync_checkpoints',
      where: 'business_id = ?',
      whereArgs: [businessId],
      limit: 1,
    );
    return rows.isNotEmpty ? rows.first['cursor_value'] as String? : null;
  }

  Future<void> setLocalCheckpoint(String businessId, String cursorValue) async {
    final db = await database;
    await db.insert('local_sync_checkpoints', {
      'business_id': businessId,
      'cursor_value': cursorValue,
      'updated_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String?> getSyncStateValue(String key) async {
    final db = await database;
    final rows = await db.query(
      'local_sync_state',
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isNotEmpty ? rows.first['value'] as String? : null;
  }

  Future<void> setSyncStateValue(String key, String value) async {
    final db = await database;
    await db.insert('local_sync_state', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // ==================== حارس signOut ضد الفقدان الصامت ====================

  /// لقطة سلامة الطابور قبل أي مسح: عدد العناصر النشطة وعدد dead_letter.
  Future<Map<String, int>> getQueueSafetySnapshot() async {
    final db = await database;
    final pending =
        Sqflite.firstIntValue(
          await db.rawQuery(
            "SELECT COUNT(*) AS count FROM offline_mutations_queue WHERE status != 'dead_letter'",
          ),
        ) ??
        0;
    final deadLetter =
        Sqflite.firstIntValue(
          await db.rawQuery(
            "SELECT COUNT(*) AS count FROM offline_mutations_queue WHERE status = 'dead_letter'",
          ),
        ) ??
        0;
    return {'pending': pending, 'deadLetter': deadLetter};
  }

  /// أرشفة الطابور والقيود/العملاء المعلقة إلى ملف JSON (خيار «أرشفة وخروج»).
  /// يعيد مسار الملف، أو null إن لم يوجد ما يُرشف.
  Future<String?> archivePendingMutations() async {
    final db = await database;
    final queue = await db.query('offline_mutations_queue', orderBy: 'id ASC');
    if (queue.isEmpty) return null;

    final pendingEntries = await db.query(
      'local_ledger_entries',
      where: "sync_status LIKE 'pending%'",
    );
    final pendingCustomers = await db.query(
      'local_business_customers',
      where: "sync_status LIKE 'pending%'",
    );

    final archive = {
      'version': 1,
      'exported_at': DateTime.now().toIso8601String(),
      'queue': queue,
      'pending_entries': pendingEntries,
      'pending_customers': pendingCustomers,
    };

    final dir = await getDatabasesPath();
    final file = File(
      join(dir, 'queue_archive_${DateTime.now().millisecondsSinceEpoch}.json'),
    );
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(archive),
    );
    return file.path;
  }

  /// استرجاع أرشيفة طابور سابقة (تُستدعى اليوم عند عرض رسالة الاسترجاع بعد الدخول).
  Future<int> restoreQueueFromArchive(String jsonContent) async {
    final db = await database;
    final decoded = jsonDecode(jsonContent);
    if (decoded is! Map<String, dynamic>) return 0;

    int restored = 0;
    await db.transaction((txn) async {
      final queue = decoded['queue'];
      if (queue is List) {
        for (final row in queue) {
          if (row is Map<String, dynamic>) {
            await txn.insert(
              'offline_mutations_queue',
              Map<String, dynamic>.from(row)..remove('id'),
              conflictAlgorithm: ConflictAlgorithm.ignore,
            );
            restored++;
          }
        }
      }
      final entries = decoded['pending_entries'];
      if (entries is List) {
        for (final row in entries) {
          if (row is Map<String, dynamic>) {
            await txn.insert(
              'local_ledger_entries',
              Map<String, dynamic>.from(row),
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          }
        }
      }
      final customers = decoded['pending_customers'];
      if (customers is List) {
        for (final row in customers) {
          if (row is Map<String, dynamic>) {
            await txn.insert(
              'local_business_customers',
              Map<String, dynamic>.from(row),
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          }
        }
      }
    });
    return restored;
  }

  /// مسح كل البيانات المحلية — محروس ضد الحذف الصامت للطابور.
  ///
  /// إن وُجدت عناصر معلقة أو dead_letter ولم يُمرَّر
  /// [allowWithPendingQueue] = true (بعد مزامنة أو أرشفة صريحة من المستخدم)،
  /// يُرمى [StateError] بدل فقدان بيانات مالية بصمت.
  Future<void> clearAll({bool allowWithPendingQueue = false}) async {
    final db = await database;

    if (!allowWithPendingQueue) {
      final snapshot = await getQueueSafetySnapshot();
      final total = (snapshot['pending'] ?? 0) + (snapshot['deadLetter'] ?? 0);
      if (total > 0) {
        throw StateError(
          'يوجد $total عملية غير مزامنة في الطابور. '
          'يجب إتمام المزامنة أو أرشفة الطابور قبل مسح البيانات المحلية.',
        );
      }
    }

    await db.transaction((txn) async {
      await txn.delete('local_customer_currency_balances');
      await txn.delete('local_disputes');
      await txn.delete('local_ledger_entries');
      await txn.delete('local_business_customers');
      await txn.delete('local_businesses');
      await txn.delete('local_profiles');
      await txn.delete('offline_mutations_queue');
      await txn.delete('local_id_map');
      await txn.delete('local_sync_checkpoints');
    });
  }
}
