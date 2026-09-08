import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../core/finance/money.dart';

typedef JsonMap = Map<String, dynamic>;

/// A separate, durable notebook, never consumed by the account sync queue.
/// Monetary values are integer ten-thousandths; balances are derived from
/// immutable entries, including reversals, rather than editable totals.
class LocalLedgerStore {
  LocalLedgerStore({DatabaseFactory? factory, String? databasePath})
    : _factory = factory ?? databaseFactory,
      _path = databasePath;

  static final instance = LocalLedgerStore();
  final DatabaseFactory _factory;
  final String? _path;
  Future<Database>? _opening;
  static const _uuid = Uuid();
  static const maxMinor = 999999999999999;

  Future<Database> get database => _opening ??= _open();

  Future<Database> _open() async {
    final location =
        _path ??
        path.join(
          await _factory.getDatabasesPath(),
          'muthbat_local_notebooks.db',
        );
    return _factory.openDatabase(
      location,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) async {
          await db.execute(
            'CREATE TABLE notebooks (id TEXT PRIMARY KEY, document TEXT NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE settings (id INTEGER PRIMARY KEY CHECK(id=1), active_id TEXT)',
          );
        },
      ),
    );
  }

  Future<JsonMap?> current() async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT n.document FROM notebooks n JOIN settings s ON s.active_id=n.id WHERE s.id=1',
    );
    return rows.isEmpty
        ? null
        : jsonDecode(rows.first['document'] as String) as JsonMap;
  }

  Future<void> create(String name, String currency) async {
    final doc = <String, dynamic>{
      'version': 1,
      'id': _uuid.v4(),
      'name': name.trim().isEmpty ? 'بقالتي' : name.trim(),
      'currency': currency,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'customers': <JsonMap>[],
      'entries': <JsonMap>[],
      'owner_id': null,
      'transfer_state': 'local',
      'server_business_id': null,
    };
    validate(doc);
    final db = await database;
    await db.transaction((txn) async {
      final active = await txn.query('settings');
      if (active.isNotEmpty && active.first['active_id'] != null) {
        throw StateError('يوجد دفتر بالفعل. افتحه أو صدّر نسخة منه أولاً.');
      }
      await txn.insert('notebooks', {
        'id': doc['id'],
        'document': jsonEncode(doc),
      });
      await txn.insert('settings', {
        'id': 1,
        'active_id': doc['id'],
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  Future<T> _edit<T>(T Function(JsonMap) action) async {
    final db = await database;
    return db.transaction((txn) async {
      final rows = await txn.rawQuery(
        'SELECT n.document FROM notebooks n JOIN settings s ON s.active_id=n.id WHERE s.id=1',
      );
      if (rows.isEmpty) throw StateError('لا يوجد دفتر محلي');
      final doc = jsonDecode(rows.first['document'] as String) as JsonMap;
      final result = action(doc);
      validate(doc);
      await txn.update(
        'notebooks',
        {'document': jsonEncode(doc)},
        where: 'id=?',
        whereArgs: [doc['id']],
      );
      return result;
    });
  }

  Future<String> record({
    String? customerId,
    String? customerName,
    required String type,
    required String amount,
    String description = '',
  }) {
    return _edit((doc) {
      if (doc['transfer_state'] != 'local') {
        throw StateError(
          'الدفتر قيد النقل أو نُقل للحساب. أكمل النقل قبل التعديل.',
        );
      }
      if (!{'debt', 'payment', 'discount'}.contains(type)) {
        throw const FormatException('نوع العملية غير صالح');
      }
      final money = Money.tryParse(normalizeDigits(amount));
      if (money == null ||
          money.minorUnits <= 0 ||
          money.minorUnits > maxMinor) {
        throw const FormatException(
          'أدخل مبلغًا موجبًا، بحد أقصى أربع منازل عشرية',
        );
      }
      final customers = doc['customers'] as List;
      final id = customerId ?? _uuid.v4();
      if (customerId == null) {
        final name = (customerName ?? '').trim();
        if (name.length < 2 || name.length > 120) {
          throw const FormatException('اسم العميل من حرفين إلى 120 حرفًا');
        }
        if (customers.any((c) => c['name'] == name)) {
          throw const FormatException('الاسم موجود؛ اختر العميل من القائمة');
        }
        customers.add({'id': id, 'name': name});
      } else if (!customers.any((c) => c['id'] == id)) {
        throw const FormatException('العميل غير موجود');
      }
      if (type == 'discount' && money.minorUnits > balance(doc, id)) {
        throw const FormatException('الخصم لا يتجاوز الدين المستحق');
      }
      (doc['entries'] as List).add({
        'id': _uuid.v4(),
        'customer_id': id,
        'type': type,
        'minor': money.minorUnits,
        'direction': type == 'debt' ? 'debit' : 'credit',
        'description': description.trim().isEmpty
            ? labels[type]!
            : description.trim(),
        'occurred_at': DateTime.now().toUtc().toIso8601String(),
        'reverses': null,
      });
      return id;
    });
  }

  Future<void> reverse(String entryId, String reason) => _edit((doc) {
    if (doc['transfer_state'] != 'local') {
      throw StateError('لا يمكن تعديل دفتر قيد النقل');
    }
    final entries = doc['entries'] as List;
    final matches = entries.where((e) => e['id'] == entryId).toList();
    if (matches.length != 1 ||
        matches.first['type'] == 'reversal' ||
        entries.any((e) => e['reverses'] == entryId)) {
      throw const FormatException(
        'هذه العملية غير قابلة للعكس أو عُكست سابقًا',
      );
    }
    if (reason.trim().length < 2) throw const FormatException('اكتب سبب العكس');
    final original = matches.first;
    entries.add({
      'id': _uuid.v4(),
      'customer_id': original['customer_id'],
      'type': 'reversal',
      'minor': original['minor'],
      'direction': original['direction'] == 'debit' ? 'credit' : 'debit',
      'description': reason.trim(),
      'occurred_at': DateTime.now().toUtc().toIso8601String(),
      'reverses': entryId,
    });
  });

  /// Persist the recipient and freeze the snapshot BEFORE making a network call.
  /// A timeout is ambiguous, so only a retry for the same account is allowed.
  Future<JsonMap> reserveTransfer(String userId) => _edit((doc) {
    if ((doc['entries'] as List).length > 20000 ||
        (doc['customers'] as List).length > 5000) {
      throw StateError(
        'هذا الدفتر يتجاوز حجم النقل الحالي. يبقى متاحًا محليًا وللنسخ الاحتياطي.',
      );
    }
    if (doc['owner_id'] != null && doc['owner_id'] != userId) {
      throw StateError('هذا الدفتر مرتبط بحساب آخر');
    }
    doc['owner_id'] = userId;
    if (doc['transfer_state'] != 'complete') {
      doc['transfer_state'] = 'transferring';
    }
    return jsonDecode(jsonEncode(doc)) as JsonMap;
  });

  Future<void> completeTransfer(String userId, String businessId) => _edit((
    doc,
  ) {
    if (doc['owner_id'] != userId) throw StateError('تغيّر الحساب أثناء النقل');
    doc['transfer_state'] = 'complete';
    doc['server_business_id'] = businessId;
  });

  Future<String> backup() async {
    final doc = await current();
    if (doc == null) throw StateError('لا يوجد دفتر');
    final payload = jsonEncode(doc);
    return jsonEncode({
      'format': 'muthbat-notebook',
      'version': 1,
      'payload': payload,
      'sha256': sha256.convert(utf8.encode(payload)).toString(),
    });
  }

  /// Validate everything before touching storage; never replace another notebook.
  Future<void> restore(String text) async {
    final doc = decodeBackup(text);
    final db = await database;
    await db.transaction((txn) async {
      if ((await txn.query('notebooks')).isNotEmpty) {
        throw StateError(
          'الاستعادة متاحة على جهاز بلا دفتر محلي؛ لن نستبدل بياناتك الحالية',
        );
      }
      await txn.insert('notebooks', {
        'id': doc['id'],
        'document': jsonEncode(doc),
      });
      await txn.insert('settings', {
        'id': 1,
        'active_id': doc['id'],
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  static JsonMap decodeBackup(String text) {
    if (utf8.encode(text).length > 20 * 1024 * 1024) {
      throw const FormatException('النسخة أكبر من الحجم المدعوم');
    }
    final envelope = jsonDecode(text);
    if (envelope is! Map ||
        envelope['format'] != 'muthbat-notebook' ||
        envelope['version'] != 1 ||
        envelope['payload'] is! String) {
      throw const FormatException('صيغة النسخة غير مدعومة');
    }
    final payload = envelope['payload'] as String;
    if (sha256.convert(utf8.encode(payload)).toString() != envelope['sha256']) {
      throw const FormatException('النسخة تالفة أو تغير محتواها');
    }
    final doc = jsonDecode(payload);
    if (doc is! JsonMap) throw const FormatException('النسخة غير صالحة');
    validate(doc);
    return doc;
  }

  static const labels = {
    'debt': 'دين',
    'payment': 'دفعة',
    'discount': 'خصم',
    'reversal': 'عكس',
  };
  static String normalizeDigits(String text) {
    for (var i = 0; i < 10; i++) {
      text = text
          .replaceAll('٠١٢٣٤٥٦٧٨٩'[i], '$i')
          .replaceAll('۰۱۲۳۴۵۶۷۸۹'[i], '$i');
    }
    return text.replaceAll('٫', '.').replaceAll('٬', '');
  }

  static int balance(JsonMap doc, String customerId) => (doc['entries'] as List)
      .where((e) => e['customer_id'] == customerId)
      .fold<int>(
        0,
        (sum, e) =>
            sum +
            (e['direction'] == 'debit'
                ? e['minor'] as int
                : -(e['minor'] as int)),
      );
  static String money(int minor) => Money.fromMinorUnits(
    minor,
  ).toDecimalString().replaceFirst(RegExp(r'\.?0+$'), '');

  static void validate(JsonMap doc) {
    final uuid = RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    );
    bool id(dynamic value) => value is String && uuid.hasMatch(value);
    bool name(dynamic value, int max) =>
        value is String && value.trim().length >= 2 && value.length <= max;
    bool date(dynamic value) =>
        value is String && DateTime.tryParse(value) != null;
    if (doc['version'] != 1 ||
        !id(doc['id']) ||
        !name(doc['name'], 120) ||
        !{'YER', 'SAR', 'USD'}.contains(doc['currency']) ||
        !date(doc['created_at']) ||
        doc['customers'] is! List ||
        doc['entries'] is! List ||
        !{
          'local',
          'transferring',
          'complete',
        }.contains(doc['transfer_state'])) {
      throw const FormatException('بيانات الدفتر غير صالحة');
    }
    if ((doc['owner_id'] != null && !id(doc['owner_id'])) ||
        (doc['transfer_state'] != 'local' && !id(doc['owner_id'])) ||
        (doc['transfer_state'] == 'complete' &&
            !id(doc['server_business_id']))) {
      throw const FormatException('بيانات ربط الدفتر غير صالحة');
    }
    final customers = <String>{};
    for (final c in doc['customers']) {
      if (c is! Map ||
          !id(c['id']) ||
          !name(c['name'], 120) ||
          !customers.add(c['id'])) {
        throw const FormatException('بيانات العملاء غير صالحة');
      }
    }
    final entries = <String, Map>{};
    final reversed = <String>{};
    final balances = <String, int>{};
    for (final e in doc['entries']) {
      if (e is! Map ||
          !id(e['id']) ||
          entries.containsKey(e['id']) ||
          !customers.contains(e['customer_id']) ||
          !labels.containsKey(e['type']) ||
          e['minor'] is! int ||
          e['minor'] <= 0 ||
          e['minor'] > maxMinor ||
          !name(e['description'], 500) ||
          !date(e['occurred_at'])) {
        throw const FormatException('بيانات القيود غير صالحة');
      }
      final type = e['type'];
      if (type == 'reversal') {
        final original = entries[e['reverses']];
        if (original == null ||
            original['type'] == 'reversal' ||
            !reversed.add(e['reverses']) ||
            original['customer_id'] != e['customer_id'] ||
            original['minor'] != e['minor'] ||
            e['direction'] !=
                (original['direction'] == 'debit' ? 'credit' : 'debit')) {
          throw const FormatException('مرجع العكس غير صالح');
        }
      } else if (e['reverses'] != null ||
          e['direction'] != (type == 'debt' ? 'debit' : 'credit')) {
        throw const FormatException('اتجاه القيد غير صالح');
      }
      final balance = balances[e['customer_id']] ?? 0;
      if (type == 'discount' && e['minor'] > balance) {
        throw const FormatException('الخصم يتجاوز الرصيد');
      }
      final next =
          balance +
          (e['direction'] == 'debit'
              ? e['minor'] as int
              : -(e['minor'] as int));
      if (next.abs() > maxMinor) {
        throw const FormatException('الرصيد يتجاوز الحد المدعوم');
      }
      balances[e['customer_id']] = next;
      entries[e['id']] = e;
    }
  }
}
