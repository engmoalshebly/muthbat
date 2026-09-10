import 'package:flutter/material.dart';
import '../../app/theme/app_colors.dart';
import 'local_ledger_store.dart';
import 'local_palette.dart';

/// Local-only directory: filtering never changes the stored ledger.
class LocalDirectory extends StatefulWidget {
  const LocalDirectory({
    super.key,
    required this.document,
    required this.onOpen,
    required this.onReverse,
    required this.onPdf,
    this.customerId,
    this.busy = false,
  });
  final JsonMap document;
  final String? customerId;
  final bool busy;
  final ValueChanged<String> onOpen;
  final ValueChanged<JsonMap> onReverse;
  final VoidCallback onPdf;
  @override
  State<LocalDirectory> createState() => _LocalDirectoryState();
}

class _LocalDirectoryState extends State<LocalDirectory> {
  String query = '';
  int filter = 0;
  bool largestFirst = false;

  Widget badge(String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .08),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      text,
      style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final d = widget.document;
    final detail = widget.customerId != null;
    final entries = LocalLedgerStore.chronological(d['entries'] as List);
    final balances = <String, int>{};
    final counts = <String, int>{};
    final reversed = <String>{};
    for (final e in entries) {
      final id = e['customer_id'] as String;
      balances[id] =
          (balances[id] ?? 0) +
          (e['direction'] == 'debit'
              ? e['minor'] as int
              : -(e['minor'] as int));
      counts[id] = (counts[id] ?? 0) + 1;
      if (e['reverses'] != null) reversed.add(e['reverses'] as String);
    }
    final customers =
        (d['customers'] as List).where((c) {
          final balance = balances[c['id']] ?? 0;
          return c['name'].toString().toLowerCase().contains(
                query.trim().toLowerCase(),
              ) &&
              (filter == 0 ||
                  filter == 1 && balance > 0 ||
                  filter == 2 && balance == 0 ||
                  filter == 3 && balance < 0);
        }).toList()..sort(
          (a, b) => largestFirst
              ? (balances[b['id']] ?? 0).compareTo(balances[a['id']] ?? 0)
              : a['name'].toString().compareTo(b['name'].toString()),
        );
    final movements = entries
        .where(
          (e) =>
              e['customer_id'] == widget.customerId &&
              (filter == 0 ||
                  filter == 1 && e['type'] == 'debt' ||
                  filter == 2 && e['type'] == 'payment' ||
                  filter == 3 &&
                      (e['type'] == 'discount' || e['type'] == 'reversal')),
        )
        .toList()
        .reversed
        .toList();
    final balance = balances[widget.customerId] ?? 0;
    final labels = detail
        ? ['الكل', 'ديون', 'دفعات', 'تسويات']
        : ['الكل', 'عليهم رصيد', 'مسددون', 'لهم رصيد'];
    final count = detail ? movements.length : customers.length;
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (detail)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.primary,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                balance < 0
                                    ? 'رصيد للعميل'
                                    : balance == 0
                                    ? 'الحساب مسدد'
                                    : 'المتبقي على العميل',
                                style: const TextStyle(
                                  color: AppColors.textWhiteSecondary,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '${LocalLedgerStore.money(balance.abs())} ${d['currency']}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 23,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: 'مشاركة كشف PDF',
                          onPressed: widget.busy ? null : widget.onPdf,
                          icon: const Icon(
                            Icons.file_download_outlined,
                            color: Colors.white,
                            size: 22,
                          ),
                        ),
                      ],
                    ),
                  )
                else ...[
                  const Text(
                    'إدارة العملاء',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      color: AppColors.primary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'الأرصدة واضحة، وكل حساب في مكانه',
                    style: TextStyle(color: LocalPalette.secondaryText),
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    onChanged: (v) => setState(() => query = v),
                    decoration: InputDecoration(
                      hintText: 'ابحث باسم العميل',
                      prefixIcon: const Icon(Icons.search_rounded),
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(
                          color: AppColors.borderLight,
                        ),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: List.generate(
                      labels.length,
                      (i) => Padding(
                        padding: const EdgeInsetsDirectional.only(end: 8),
                        child: ChoiceChip(
                          label: Text(labels[i]),
                          selected: filter == i,
                          showCheckmark: false,
                          selectedColor: AppColors.primary,
                          labelStyle: TextStyle(
                            color: filter == i
                                ? Colors.white
                                : LocalPalette.secondaryText,
                          ),
                          onSelected: (_) => setState(() => filter = i),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        detail ? 'سجل الحركات · $count' : '$count عميل',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          color: LocalPalette.secondaryText,
                        ),
                      ),
                    ),
                    if (!detail)
                      TextButton.icon(
                        onPressed: () =>
                            setState(() => largestFirst = !largestFirst),
                        icon: const Icon(Icons.sort, size: 18),
                        label: Text(
                          largestFirst ? 'الأعلى مديونية' : 'حسب الاسم',
                        ),
                      ),
                  ],
                ),
                if (d['transfer_state'] != 'local')
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'نسخة للقراءة • تابع حالة نقل الدفتر من الحساب',
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (count == 0)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(40),
              child: Column(
                children: [
                  Icon(
                    Icons.search_off_rounded,
                    size: 42,
                    color: AppColors.textMuted,
                  ),
                  SizedBox(height: 12),
                  Text('لا توجد نتائج في هذه القائمة'),
                  SizedBox(height: 6),
                  Text(
                    'جرّب تغيير البحث أو الفلتر',
                    style: TextStyle(color: LocalPalette.secondaryText),
                  ),
                ],
              ),
            ),
          ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 110),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate((context, index) {
              final item = detail ? movements[index] : customers[index];
              final amount = detail
                  ? item['minor'] as int
                  : balances[item['id']] ?? 0;
              final undone = detail && reversed.contains(item['id']);
              final color = detail
                  ? (undone
                        ? LocalPalette.secondaryText
                        : item['direction'] == 'debit'
                        ? LocalPalette.debt
                        : LocalPalette.payment)
                  : amount > 0
                  ? LocalPalette.debt
                  : amount < 0
                  ? LocalPalette.teal
                  : LocalPalette.secondaryText;
              final name = detail
                  ? LocalLedgerStore.labels[item['type']] ?? 'عملية'
                  : item['name'] as String;
              final description = detail
                  ? item['description'].toString().trim()
                  : '${counts[item['id']] ?? 0} حركة مسجلة';
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Material(
                  color: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: const BorderSide(color: AppColors.borderSubtle),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: detail ? null : () => widget.onOpen(item['id']),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 34,
                                height: 34,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: LocalPalette.mint,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: detail
                                    ? Icon(
                                        item['direction'] == 'debit'
                                            ? Icons.north_east
                                            : Icons.south_west,
                                        color: color,
                                        size: 20,
                                      )
                                    : Text(
                                        name.characters.first,
                                        style: const TextStyle(
                                          color: AppColors.primary,
                                          fontWeight: FontWeight.w800,
                                          fontSize: 18,
                                        ),
                                      ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      name,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w700,
                                        color: AppColors.textPrimary,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      detail
                                          ? LocalLedgerStore.localDate(
                                              item['occurred_at'],
                                            )
                                          : description,
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: LocalPalette.secondaryText,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text(
                                      '${LocalLedgerStore.money(amount.abs())} ${d['currency']}',
                                      textAlign: TextAlign.end,
                                      style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w800,
                                        color: color,
                                      ),
                                    ),
                                    Text(
                                      detail
                                          ? undone
                                                ? 'معكوسة'
                                                : item['direction'] == 'debit'
                                                ? 'عليه'
                                                : 'تخفيض الرصيد'
                                          : amount > 0
                                          ? 'عليه رصيد'
                                          : amount < 0
                                          ? 'له رصيد'
                                          : 'مسدد',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: color,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (!detail)
                                const Icon(
                                  Icons.chevron_left,
                                  size: 20,
                                  color: AppColors.textMuted,
                                ),
                            ],
                          ),
                          if (detail &&
                              description.isNotEmpty &&
                              description != name)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                description,
                                style: const TextStyle(
                                  color: LocalPalette.secondaryText,
                                ),
                              ),
                            ),
                          if (detail && item['category'] != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                'التصنيف: ${item['category']}',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: LocalPalette.secondaryText,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }, childCount: count),
          ),
        ),
      ],
    );
  }
}
