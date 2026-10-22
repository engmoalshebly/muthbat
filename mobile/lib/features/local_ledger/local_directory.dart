import 'package:flutter/material.dart';
import '../../app/theme/app_colors.dart';
import 'local_ledger_store.dart';
import 'local_palette.dart';
import 'local_category_filter.dart';
import '../../app/theme/app_icons.dart';

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
  String? category;
  int filter = 0;
  bool largestFirst = false;
  String? expandedMovement;

  Widget customerCard(
    JsonMap customer,
    int amount,
    int count,
    String currency,
  ) {
    final color = AppColors.customerStatusColor(amount);
    final name = customer['name'].toString();
    final phone = customer['phone']?.toString() ?? '';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Color.alphaBlend(
          color.withValues(alpha: .045),
          AppColors.surfaceLight,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: color.withValues(alpha: .22)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => widget.onOpen(customer['id']),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      width: 30,
                      height: 30,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: .10),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        name.isEmpty ? '؟' : name.characters.first,
                        style: TextStyle(
                          color: color,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textPrimary,
                            ),
                          ),
                          if (phone.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Row(
                              children: [
                                const Icon(
                                  AppIcons.phone,
                                  size: 12,
                                  color: AppColors.textMuted,
                                ),
                                const SizedBox(width: 5),
                                Flexible(
                                  child: Text(
                                    phone,
                                    textDirection: TextDirection.ltr,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      color: AppColors.textSecondary,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Icon(
                      AppIcons.chevronEnd,
                      size: 18,
                      color: AppColors.textMuted,
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 12,
                  runSpacing: 4,
                  children: [
                    Text(
                      '$count عملية',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: .08),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        amount == 0
                            ? '✓ مسدد'
                            : '${amount > 0 ? 'مديون' : 'له رصيد مقدم'}  ${LocalLedgerStore.money(amount.abs())} $currency',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: color,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget badge(String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .08),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      text,
      style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w600),
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
          return LocalLedgerStore.matchesCustomer(c, query) &&
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
              (category == null || ledgerCategory(e) == category) &&
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
    final accountEntries = entries
        .where((e) => e['customer_id'] == widget.customerId)
        .toList();
    final statusColor = AppColors.customerStatusColor(balance);
    final labels = detail
        ? ['الكل', 'ديون', 'دفعات', 'تسويات']
        : ['الكل', 'عليهم رصيد', 'مسددون', 'لهم رصيد'];
    final count = detail ? movements.length : customers.length;
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
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
                      color: statusColor,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(7),
                              decoration: BoxDecoration(
                                color: AppColors.white.withValues(alpha: .15),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(
                                balance == 0 ? AppIcons.check : AppIcons.wallet,
                                size: 17,
                                color: AppColors.white,
                              ),
                            ),
                            const SizedBox(width: 9),
                            Expanded(
                              child: Text(
                                balance > 0
                                    ? 'العميل مديون • المتبقي عليه'
                                    : balance < 0
                                    ? 'للعميل رصيد مقدم'
                                    : accountEntries.isEmpty
                                    ? 'لا توجد عمليات'
                                    : 'الحساب مسدد',
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.white,
                                ),
                              ),
                            ),
                            TextButton.icon(
                              onPressed: widget.busy ? null : widget.onPdf,
                              style: TextButton.styleFrom(
                                foregroundColor: AppColors.white,
                                backgroundColor: AppColors.white.withValues(
                                  alpha: .15,
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 9,
                                  vertical: 6,
                                ),
                                minimumSize: const Size(0, 36),
                              ),
                              icon: const Icon(
                                AppIcons.receipt,
                                size: 16,
                                color: AppColors.white,
                              ),
                              label: const Text(
                                'عرض التقرير',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${LocalLedgerStore.money(balance.abs())} ${d['currency']}',
                          style: const TextStyle(
                            fontSize: 24,
                            height: 1.2,
                            fontWeight: FontWeight.w800,
                            color: AppColors.white,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '${accountEntries.length} عملية مسجلة',
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.textWhiteSecondary,
                          ),
                        ),
                      ],
                    ),
                  )
                else ...[
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: AppColors.primaryContainer,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: const Icon(
                          AppIcons.customers,
                          size: 20,
                          color: AppColors.primary,
                        ),
                      ),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'عملاؤك',
                          style: TextStyle(
                            fontSize: 21,
                            fontWeight: FontWeight.w800,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                      badge(
                        '${(d['customers'] as List).length} عميل',
                        AppColors.primary,
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'تابع الأرصدة وافتح حساب أي عميل بسهولة',
                    style: TextStyle(color: LocalPalette.secondaryText),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    onChanged: (v) => setState(() => query = v),
                    decoration: InputDecoration(
                      hintText: 'ابحث بالاسم أو رقم الهاتف',
                      prefixIcon: const Icon(AppIcons.search, size: 19),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 14,
                      ),
                      filled: true,
                      fillColor: AppColors.white,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(
                          color: AppColors.borderLight,
                        ),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                if (detail) ...[
                  LocalCategoryFilter(
                    entries: accountEntries,
                    value: category,
                    onChanged: (v) => setState(() {
                      category = v;
                      expandedMovement = null;
                    }),
                  ),
                  const SizedBox(height: 10),
                ],
                Container(
                  decoration: const BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: AppColors.borderLight),
                    ),
                  ),
                  child: Row(
                    children: List.generate(labels.length, (i) {
                      final selected = filter == i;
                      final color = detail
                          ? [
                              AppColors.primary,
                              AppColors.debt,
                              AppColors.payment,
                              AppColors.discount,
                            ][i]
                          : [
                              AppColors.primary,
                              AppColors.debt,
                              AppColors.settled,
                              AppColors.customerCredit,
                            ][i];
                      return Expanded(
                        child: Semantics(
                          selected: selected,
                          button: true,
                          child: Material(
                            color: AppColors.transparent,
                            child: InkWell(
                              onTap: () => setState(() => filter = i),
                              borderRadius: BorderRadius.circular(8),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 180),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 2,
                                  vertical: 12,
                                ),
                                decoration: BoxDecoration(
                                  border: Border(
                                    bottom: BorderSide(
                                      color: selected
                                          ? color
                                          : AppColors.transparent,
                                      width: 3,
                                    ),
                                  ),
                                ),
                                child: Text(
                                  labels[i],
                                  textAlign: TextAlign.center,
                                  maxLines: 1,
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: selected
                                        ? FontWeight.w800
                                        : FontWeight.w500,
                                    color: selected
                                        ? color
                                        : AppColors.textSecondary,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    }),
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
                        icon: const Icon(AppIcons.filter, size: 16),
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
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 110),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate((context, index) {
              final item = detail ? movements[index] : customers[index];
              final amount = detail
                  ? item['minor'] as int
                  : balances[item['id']] ?? 0;
              if (!detail) {
                return customerCard(
                  JsonMap.from(item),
                  amount,
                  counts[item['id']] ?? 0,
                  d['currency'].toString(),
                );
              }
              final undone = detail && reversed.contains(item['id']);
              final expanded = expandedMovement == item['id'];
              final color = detail
                  ? (undone
                        ? LocalPalette.secondaryText
                        : AppColors.transactionColor(item['type'].toString()))
                  : AppColors.balanceColor(amount);
              final name = detail
                  ? LocalLedgerStore.labels[item['type']] ?? 'عملية'
                  : item['name'] as String;
              final description = detail
                  ? item['description'].toString().trim()
                  : '${counts[item['id']] ?? 0} حركة مسجلة';
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Material(
                  color: AppColors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: const BorderSide(color: AppColors.borderSubtle),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => setState(
                      () => expandedMovement = expanded ? null : item['id'],
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 9,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 32,
                                height: 32,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: color.withValues(alpha: .08),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: detail
                                    ? Icon(
                                        AppIcons.transaction(
                                          item['type'].toString(),
                                        ),
                                        color: color,
                                        size: 17,
                                      )
                                    : Text(
                                        name.isEmpty
                                            ? '؟'
                                            : name.characters.first,
                                        style: const TextStyle(
                                          color: AppColors.primary,
                                          fontWeight: FontWeight.w800,
                                          fontSize: 19,
                                        ),
                                      ),
                              ),
                              const SizedBox(width: 9),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 15,
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
                              Flexible(
                                fit: FlexFit.tight,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text(
                                      '${LocalLedgerStore.money(amount.abs())} ${d['currency']}',
                                      textAlign: TextAlign.end,
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w800,
                                        color: color,
                                      ),
                                    ),
                                    if (undone || expanded)
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
                                            : '✓ مسدد',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: color,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 12),
                              Icon(
                                expanded
                                    ? AppIcons.chevronUp
                                    : AppIcons.chevronDown,
                                size: 16,
                                color: AppColors.textMuted,
                              ),
                            ],
                          ),
                          if (expanded &&
                              detail &&
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
                          if (expanded && detail && item['category'] != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                'التصنيف: ${item['category']}',
                                style: const TextStyle(
                                  fontSize: 13,
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
