import 'package:flutter_test/flutter_test.dart';
import '../lib/features/merchant/data/models/ledger_entry_model.dart';

void main() {
  test('custom imported category survives cache serialization', () {
    const entry = LedgerEntryModel(
      id: 'entry', businessId: 'business', businessCustomerId: 'customer',
      entryType: 'debt', direction: 'debit', amount: 25,
      description: 'مواد غذائية', occurredAt: '2026-09-10T08:00:00Z',
      clientRequestId: 'request', localCategoryLabel: 'مشتريات المنزل',
    );
    final restored = LedgerEntryModel.fromMap(entry.toMap());
    expect(restored.localCategoryLabel, 'مشتريات المنزل');
    expect(restored.category, 'goods');
    final legacy = entry.toMap()..remove('local_category_label');
    expect(LedgerEntryModel.fromMap(legacy).localCategoryLabel, isNull);
  });
}
