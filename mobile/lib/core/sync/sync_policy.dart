const financialSyncCommands = <String>{
  'create_ledger_entry',
  'apply_customer_discount',
  'reverse_ledger_entry',
};

const discardableSyncCommands = <String>{
  'update_business_profile',
  'upload_attachment',
  'generate_statement',
};

bool isFinancialSyncCommand(String commandType) =>
    financialSyncCommands.contains(commandType);

bool canDiscardSyncCommand(String commandType) =>
    discardableSyncCommands.contains(commandType);

class SyncAccountChanged implements Exception {
  const SyncAccountChanged();

  @override
  String toString() => 'sync_account_changed';
}

void assertSyncAccount({required String expected, required String? current}) {
  if (expected != current) throw const SyncAccountChanged();
}

Future<List<T>> collectAllPages<T>({
  required Future<List<T>> Function(int from, int to) fetchPage,
  int pageSize = 500,
}) async {
  if (pageSize <= 0) throw ArgumentError.value(pageSize, 'pageSize');
  final result = <T>[];
  var offset = 0;
  while (true) {
    final page = await fetchPage(offset, offset + pageSize - 1);
    result.addAll(page);
    if (page.length < pageSize) return result;
    offset += pageSize;
  }
}
