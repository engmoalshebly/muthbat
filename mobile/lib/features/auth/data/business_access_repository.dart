import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/database/app_database.dart';
import '../../../core/security/cloud_session.dart';

/// A device cache for UI routing; server RLS remains authoritative.
class BusinessAccess {
  const BusinessAccess({required this.businessId, required this.role});
  final String businessId;
  final String role;
}

class BusinessAccessRepository {
  BusinessAccessRepository({SupabaseClient? client}) : _client = client;
  final SupabaseClient? _client;
  static const cacheKey = 'business_access_v1';
  Future<bool> locallyDenied(String userId) async {
    final db = AppDatabase.instance;
    if (db.accountId != userId) return true;
    final raw = await db.getSyncStateValue(cacheKey);
    if (raw == null) return false;
    try {
      final value = jsonDecode(raw);
      return value is Map &&
          value['user_id'] == userId &&
          value['denied'] == true;
    } on FormatException {
      return false;
    }
  }

  static const roles = {
    'owner',
    'admin',
    'accountant',
    'cashier',
    'collector',
    'viewer',
  };

  Future<BusinessAccess?> cached(String userId) async {
    final db = AppDatabase.instance;
    if (db.accountId != userId) return null;
    final raw = await db.getSyncStateValue(cacheKey);
    if (raw == null) return null;
    Object? value;
    try {
      value = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (value is! Map ||
        value['user_id'] != userId ||
        value['business_id'] is! String ||
        !roles.contains(value['role'])) {
      return null;
    }
    return BusinessAccess(
      businessId: value['business_id'] as String,
      role: value['role'] as String,
    );
  }

  Future<BusinessAccess?> load(
    String userId, {
    String? preferredBusinessId,
    bool requireOwnership = false,
    bool Function()? isCurrent,
  }) async {
    final client = _client ?? Supabase.instance.client;
    final db = AppDatabase.instance;
    requireCloudSession(client, userId);
    final cachedAccess = await cached(userId);
    var preferred = preferredBusinessId ?? cachedAccess?.businessId;
    if (preferred != null) {
      preferred = await db.getServerId(preferred) ?? preferred;
      if (preferred.startsWith('biz-') && requireOwnership) {
        throw StateError('انتظر اكتمال مزامنة النشاط قبل تنفيذ هذه العملية');
      }
      if (preferred.startsWith('biz-') && !requireOwnership) {
        final local = await (await db.database).query(
          'local_businesses',
          where: 'id = ? AND owner_user_id = ?',
          whereArgs: [preferred, userId],
          limit: 1,
        );
        if (local.isNotEmpty &&
            db.accountId == userId &&
            isCurrent?.call() != false) {
          return BusinessAccess(businessId: preferred, role: 'owner');
        }
      }
    }
    Map<String, dynamic>? business;
    String? role;
    Future<List<Map<String, dynamic>>> readMemberships() async {
      final rows = await client
          .from('business_members')
          .select('role,businesses!inner(*)')
          .eq('user_id', userId)
          .eq('status', 'active')
          .eq('businesses.status', 'active')
          .order('business_id')
          .limit(100)
          .timeout(const Duration(seconds: 8));
      return List<Map<String, dynamic>>.from(rows);
    }

    // On a new device these lookups are independent. Owners can enter as soon
    // as ownership is confirmed, without waiting for an unrelated team lookup.
    Object? membershipError;
    StackTrace? membershipStack;
    final memberships = preferred == null && !requireOwnership
        ? readMemberships().catchError((Object error, StackTrace stack) {
            membershipError = error;
            membershipStack = stack;
            return <Map<String, dynamic>>[];
          })
        : null;
    if (preferred != null) {
      final members = await client
          .from('business_members')
          .select('role,businesses!inner(*)')
          .eq('user_id', userId)
          .eq('business_id', preferred)
          .eq('status', 'active')
          .eq('businesses.status', 'active')
          .limit(1)
          .timeout(const Duration(seconds: 8));
      if (members.isNotEmpty &&
          members.first['businesses'] is Map &&
          roles.contains(members.first['role'])) {
        business = Map<String, dynamic>.from(
          members.first['businesses'] as Map,
        );
        role = members.first['role'] as String;
        if (role == 'owner' && business['owner_user_id'] != userId) {
          business = null;
          role = null;
        }
        if (requireOwnership && role != 'owner') {
          business = null;
          role = null;
        }
      }
      if (business == null && preferredBusinessId != null) {
        throw StateError('تعذر تأكيد الوصول إلى النشاط المنقول. أعد المحاولة.');
      }
    }
    if (business == null) {
      final ownedRows = await client
          .from('businesses')
          .select()
          .eq('owner_user_id', userId)
          .eq('status', 'active')
          .order('id')
          .limit(100)
          .timeout(const Duration(seconds: 8));
      final owned = ownedRows.cast<Map<String, dynamic>>();
      if (owned.isNotEmpty) {
        business = owned.firstWhere(
          (row) => row['id'] == cachedAccess?.businessId,
          orElse: () => owned.first,
        );
        role = 'owner';
      }
    }
    if (business == null && !requireOwnership) {
      final members = await (memberships ?? readMemberships());
      if (membershipError != null) {
        Error.throwWithStackTrace(membershipError!, membershipStack!);
      }
      final eligibleMembers = members.where((member) {
        if (member['businesses'] is! Map || !roles.contains(member['role'])) {
          return false;
        }
        final businessRow = Map<String, dynamic>.from(
          member['businesses'] as Map,
        );
        return member['role'] != 'owner' ||
            businessRow['owner_user_id'] == userId;
      }).toList();
      final selectedMember = eligibleMembers
          .cast<Map<String, dynamic>?>()
          .firstWhere(
            (member) =>
                (member?['businesses'] as Map?)?['id'] ==
                cachedAccess?.businessId,
            orElse: () =>
                eligibleMembers.isEmpty ? null : eligibleMembers.first,
          );
      if (selectedMember != null && selectedMember['businesses'] is Map) {
        business = Map<String, dynamic>.from(
          selectedMember['businesses'] as Map,
        );
        role = selectedMember['role'] as String;
      }
    }
    requireCloudSession(client, userId);
    if (isCurrent?.call() == false) throw StateError('Stale access lookup');
    if (db.accountId != userId) throw StateError('Account changed');
    if (business == null || role == null) {
      await db.setSyncStateValue(
        cacheKey,
        jsonEncode({'user_id': userId, 'denied': true}),
      );
      return null;
    }
    final id = business['id'] as String;
    await db.saveBusiness({
      'id': id,
      'owner_user_id': business['owner_user_id'],
      'name': business['name'],
      'business_type': business['business_type'],
      'currency_code': business['currency_code'] ?? 'YER',
      'additional_currencies': jsonEncode(
        business['additional_currencies'] ?? [],
      ),
      'country_code': business['country_code'] ?? 'YE',
      'city': business['city'],
      'address': business['address'],
      'contact_phone': business['contact_phone_display'],
      'logo_path': business['logo_path'],
      'timezone': business['timezone'],
      'is_active': 1,
      'created_at': business['created_at'],
    });
    if (isCurrent?.call() == false || db.accountId != userId) {
      throw StateError('Stale access lookup');
    }
    await db.setSyncStateValue(
      cacheKey,
      jsonEncode({'user_id': userId, 'business_id': id, 'role': role}),
    );
    return BusinessAccess(businessId: id, role: role);
  }
}
