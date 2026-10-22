import '../../../core/finance/money.dart';
import 'models/ledger_entry_model.dart';

/// Mirrors create_statement: immutable originals and their counter-entries
/// both contribute, with an inclusive start and exclusive end.
class LocalStatementTotals {
  final Money opening;
  final Money debits;
  final Money credits;

  const LocalStatementTotals({
    required this.opening,
    required this.debits,
    required this.credits,
  });

  Money get closing => opening + debits - credits;

  static LocalStatementTotals calculate({
    required Iterable<LedgerEntryModel> entries,
    required DateTime from,
    required DateTime to,
    required String currencyCode,
  }) {
    if (!to.isAfter(from)) {
      throw ArgumentError('Statement period end must be after its start');
    }
    var opening = const Money.fromMinorUnits(0);
    var debits = const Money.fromMinorUnits(0);
    var credits = const Money.fromMinorUnits(0);
    final currency = currencyCode.toUpperCase();
    for (final entry in entries) {
      if (entry.currencyCode.toUpperCase() != currency) continue;
      final occurredAt = DateTime.tryParse(entry.occurredAt);
      if (occurredAt == null || !occurredAt.isBefore(to)) continue;
      final amount = Money.fromNum(entry.amount);
      if (occurredAt.isBefore(from)) {
        opening += entry.direction == 'credit'
            ? const Money.fromMinorUnits(0) - amount
            : amount;
      } else if (entry.direction == 'credit') {
        credits += amount;
      } else {
        debits += amount;
      }
    }
    return LocalStatementTotals(
      opening: opening,
      debits: debits,
      credits: credits,
    );
  }
}
