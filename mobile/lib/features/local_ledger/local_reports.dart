import 'dart:math' as math;
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../app/theme/app_colors.dart';
import '../../app/theme/app_icons.dart';
import 'local_ledger_store.dart';
import 'local_category_filter.dart';
import '../../shared/widgets/brand_logo.dart';

/// Activity follows the selected range; balances are closing balances for
/// customers with ledger activity in that range.
class LocalReports extends StatefulWidget {
  const LocalReports({super.key, required this.document});
  final JsonMap document;

  @override
  State<LocalReports> createState() => _LocalReportsState();
}

class _LocalReportsState extends State<LocalReports> {
  int period = 30;
  String? category;
  DateTimeRange? customRange;

  Future<void> chooseRange() async {
    final now = DateTime.now();
    final selected = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(now.year, now.month, now.day),
      initialDateRange: customRange,
      helpText: 'اختر فترة التقرير',
      saveText: 'تطبيق الفترة',
    );
    if (!mounted || selected == null) return;
    setState(() {
      customRange = selected;
      period = -1;
    });
  }

  String money(int minor) => LocalLedgerStore.money(minor);

  Widget section(String title, String caption) => Padding(
    padding: const EdgeInsets.only(top: 6, bottom: 10),
    child: Row(
      children: [
        Container(
          width: 3,
          height: 28,
          decoration: BoxDecoration(
            color: AppColors.primary,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary,
                ),
              ),
              Text(
                caption,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget panel(String title, String subtitle, Widget child) {
    final detail =
        title == 'أعلى الأرصدة المستحقة' || title == 'العمليات حسب التصنيف';
    final icon = title.contains('العملاء')
        ? AppIcons.customers
        : title.contains('التصنيف')
        ? AppIcons.filter
        : AppIcons.reports;
    final heading = Row(
      children: [
        Container(
          padding: const EdgeInsets.all(7),
          decoration: BoxDecoration(
            color: AppColors.primaryContainer,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Icon(icon, size: 16, color: AppColors.primary),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: AppColors.textPrimary,
            ),
          ),
        ),
      ],
    );
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.borderLight),
      ),
      clipBehavior: Clip.antiAlias,
      child: detail
          ? Theme(
              data: Theme.of(
                context,
              ).copyWith(dividerColor: AppColors.transparent),
              child: ExpansionTile(
                key: PageStorageKey('report-$title'),
                tilePadding: const EdgeInsets.symmetric(
                  horizontal: 13,
                  vertical: 3,
                ),
                childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
                title: heading,
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
                children: [child],
              ),
            )
          : Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  heading,
                  const SizedBox(height: 6),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 16),
                  child,
                ],
              ),
            ),
    );
  }

  Widget legend(String label, Color color) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      const SizedBox(width: 6),
      Text(
        label,
        style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final doc = widget.document;
    final currency = doc['currency'].toString();
    final entries = List<JsonMap>.from(
      (doc['entries'] as List).map((e) => JsonMap.from(e)),
    );
    final allCustomers = List<JsonMap>.from(
      (doc['customers'] as List).map((e) => JsonMap.from(e)),
    );
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final lastDay = period == -1 ? customRange!.end : today;
    final end = DateTime(lastDay.year, lastDay.month, lastDay.day + 1);
    final start = period == -1
        ? customRange!.start
        : period == 0
        ? null
        : DateTime(today.year, today.month, today.day - period + 1);
    DateTime date(JsonMap e) => DateTime.parse(e['occurred_at']).toLocal();
    final history = entries.where((e) => date(e).isBefore(end)).toList();
    final reversed = history
        .where((e) => e['reverses'] != null)
        .map((e) => e['reverses'])
        .toSet();
    final effective = history
        .where((e) => e['type'] != 'reversal' && !reversed.contains(e['id']))
        .toList();
    final activeIds = history
        .where(
          (e) =>
              (start == null || !date(e).isBefore(start)) &&
              (category == null || ledgerCategory(e) == category),
        )
        .map((e) => e['customer_id'])
        .toSet();
    final customers = allCustomers
        .where((c) => activeIds.contains(c['id']))
        .toList();
    final periodLabel = start == null
        ? 'كل الفترات حتى ${DateFormat('yyyy/MM/dd').format(lastDay)}'
        : '${DateFormat('yyyy/MM/dd').format(start)} — ${DateFormat('yyyy/MM/dd').format(lastDay)}';
    final activity = effective
        .where(
          (e) =>
              (start == null || !date(e).isBefore(start)) &&
              date(e).isBefore(end) &&
              (category == null || ledgerCategory(e) == category),
        )
        .toList();
    int sum(String type) => activity
        .where((e) => e['type'] == type)
        .fold(0, (v, e) => v + (e['minor'] as int));
    final debts = sum('debt'),
        payments = sum('payment'),
        discounts = sum('discount');
    final balances = {for (final c in customers) c['id'].toString(): 0};
    for (final e in history) {
      final id = e['customer_id'].toString();
      if (!balances.containsKey(id)) continue;
      balances[id] =
          (balances[id] ?? 0) +
          (e['direction'] == 'debit'
              ? e['minor'] as int
              : -(e['minor'] as int));
    }
    final receivable = balances.values
        .where((v) => v > 0)
        .fold<int>(0, (a, b) => a + b);
    final credit = balances.values
        .where((v) => v < 0)
        .fold<int>(0, (a, b) => a - b);
    final hasBoth = receivable > 0 && credit > 0;
    final balanceColor = hasBoth
        ? AppColors.warning
        : receivable > 0
        ? AppColors.receivable
        : credit > 0
        ? AppColors.customerCredit
        : AppColors.textSecondary;
    final balanceTitle = hasBoth
        ? 'مستحقات وأرصدة مقدمة'
        : receivable > 0
        ? 'مستحقات قائمة'
        : credit > 0
        ? 'أرصدة مقدمة للعملاء'
        : 'لا توجد أرصدة معلقة';
    final owing = customers.where((c) => (balances[c['id']] ?? 0) > 0).length;
    final prepaid = customers.where((c) => (balances[c['id']] ?? 0) < 0).length;
    final settled = customers.length - owing - prepaid;
    final top = customers.where((c) => (balances[c['id']] ?? 0) > 0).toList()
      ..sort((a, b) => balances[b['id']]!.compareTo(balances[a['id']]!));

    // Daily buckets for short periods, five-day buckets for a month,
    // and calendar months across the full history.
    final dates = <DateTime>[];
    final days = start == null ? 0 : lastDay.difference(start).inDays + 1;
    final monthly = start == null || days > 62;
    if (monthly) {
      final sorted = activity.map(date).toList()..sort();
      final first = start ?? (sorted.isEmpty ? lastDay : sorted.first);
      var cursor = DateTime(first.year, first.month);
      while (!cursor.isAfter(lastDay)) {
        dates.add(cursor);
        cursor = DateTime(cursor.year, cursor.month + 1);
      }
    } else {
      for (
        var i = 0;
        i < days;
        i += days <= 7
            ? 1
            : days <= 31
            ? 5
            : 7
      ) {
        dates.add(DateTime(start.year, start.month, start.day + i));
      }
    }
    final debtBuckets = List<int>.filled(dates.length, 0);
    final paymentBuckets = List<int>.filled(dates.length, 0);
    for (final e in activity) {
      final at = date(e);
      final i = dates.lastIndexWhere((d) => !at.isBefore(d));
      if (i < 0) continue;
      if (e['type'] == 'debt') debtBuckets[i] += e['minor'] as int;
      if (e['type'] == 'payment') paymentBuckets[i] += e['minor'] as int;
    }
    final peak = [...debtBuckets, ...paymentBuckets].fold<int>(0, math.max);
    final metrics = [
      ('ديون مسجلة', debts, AppIcons.debt, AppColors.debt),
      ('دفعات مستلمة', payments, AppIcons.receivePayment, AppColors.payment),
      ('خصومات ممنوحة', discounts, AppIcons.discount, AppColors.discount),
      (
        'صافي الحركة',
        debts - payments - discounts,
        AppIcons.wallet,
        AppColors.primary,
      ),
    ];
    final categories = <String, List<int>>{};
    for (final e in activity) {
      final type = e['type'];
      if (type != 'debt' && type != 'payment' && type != 'discount') continue;
      final label = e['category']?.toString().trim() ?? '';
      final values = categories.putIfAbsent(
        label.isEmpty ? 'غير مصنف' : label,
        () => [0, 0, 0],
      );
      values[type == 'debt'
              ? 0
              : type == 'payment'
              ? 1
              : 2] +=
          e['minor'] as int;
    }
    final sortedCategories = categories.entries.toList()
      ..sort(
        (a, b) => b.value
            .fold<int>(0, (v, n) => v + n)
            .compareTo(a.value.fold<int>(0, (v, n) => v + n)),
      );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: AppColors.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const BrandLogo.icon(width: 34, height: 34),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'التقرير المالي',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    Text(
                      'دفتر ${doc['name'] ?? 'الحسابات'} • $currency',
                      style: const TextStyle(
                        fontSize: 13,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              PopupMenuButton<int>(
                tooltip: periodLabel,
                initialValue: period,
                onSelected: (v) {
                  if (v == -1) {
                    chooseRange();
                  } else {
                    setState(() => period = v);
                  }
                },
                itemBuilder: (_) => [
                  for (final option in [
                    (7, '٧ أيام'),
                    (30, '٣٠ يومًا'),
                    (0, 'كل الفترات'),
                    (-1, 'فترة مخصصة'),
                  ])
                    CheckedPopupMenuItem(
                      value: option.$1,
                      checked: period == option.$1,
                      child: Text(option.$2),
                    ),
                ],
                child: CompactFilterLabel(
                  icon: AppIcons.calendar,
                  label: period == -1
                      ? periodLabel
                      : period == 7
                      ? '٧ أيام'
                      : period == 30
                      ? '٣٠ يومًا'
                      : 'كل الفترات',
                  active: period != 0,
                ),
              ),
              LocalCategoryFilter(
                entries: entries,
                value: category,
                onChanged: (v) => setState(() => category = v),
              ),
              if (period != 30 || category != null)
                TextButton(
                  onPressed: () => setState(() {
                    period = 30;
                    category = null;
                  }),
                  child: const Text(
                    'إعادة ضبط',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            periodLabel,
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 10),
          section(
            'ملخص الحسابات',
            'أرصدة العملاء المطابقين للفلاتر حتى نهاية الفترة',
          ),
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: balanceColor,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(
                      receivable == 0 && credit == 0
                          ? AppIcons.check
                          : AppIcons.wallet,
                      size: 17,
                      color: AppColors.white,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        balanceTitle,
                        style: const TextStyle(
                          color: AppColors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '${money(receivable > 0 ? receivable : credit)} $currency',
                  style: const TextStyle(
                    fontSize: 25,
                    fontWeight: FontWeight.w800,
                    color: AppColors.white,
                  ),
                ),
                Text(
                  receivable > 0
                      ? 'إجمالي المستحق لك • $owing عميل'
                      : credit > 0
                      ? 'رصيد مقدم محفوظ للعملاء'
                      : customers.isEmpty
                      ? 'لا توجد حركة خلال الفترة'
                      : 'أرصدة العملاء المحددين متوازنة',
                  style: const TextStyle(fontSize: 13, color: AppColors.white),
                ),
                if (hasBoth) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      const Text(
                        'أرصدة مقدمة للعملاء',
                        style: TextStyle(color: AppColors.white, fontSize: 13),
                      ),
                      Text(
                        '${money(credit)} $currency',
                        style: const TextStyle(
                          color: AppColors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 6),
                const Text(
                  'أرصدة العملاء ذوي الحركة في الفترة • حتى نهايتها',
                  style: TextStyle(color: AppColors.white, fontSize: 11),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          section(
            'حركة الفترة',
            '${activity.length} عملية فعالة • ${customers.length} عميل ذوو حركة',
          ),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth < 300 ? 1 : 2;
              return Wrap(
                spacing: 10,
                runSpacing: 10,
                children: metrics
                    .map(
                      (m) => Container(
                        width:
                            (constraints.maxWidth - (columns - 1) * 10) /
                            columns,
                        padding: const EdgeInsets.all(11),
                        decoration: BoxDecoration(
                          color: Color.alphaBlend(
                            m.$4.withValues(alpha: .07),
                            AppColors.surfaceLight,
                          ),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: m.$4.withValues(alpha: .15),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(m.$3, size: 16, color: m.$4),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    m.$1,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      color: AppColors.textPrimary,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '${money(m.$2)} $currency',
                              style: TextStyle(
                                fontSize: 19,
                                fontWeight: FontWeight.w800,
                                color: m.$4,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                    .toList(),
              );
            },
          ),
          const SizedBox(height: 14),
          panel(
            'حركة الديون والتحصيل',
            'مقارنة المبالغ خلال الفترة • $currency',
            Column(
              children: [
                Wrap(
                  spacing: 20,
                  runSpacing: 8,
                  children: [
                    legend('ديون', AppColors.debt),
                    legend('دفعات', AppColors.payment),
                  ],
                ),
                const SizedBox(height: 18),
                if (peak == 0)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('لا توجد ديون أو دفعات في هذه الفترة'),
                  )
                else
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final width = math.max(
                        constraints.maxWidth,
                        dates.length * 54.0,
                      );
                      return SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: SizedBox(
                          width: width,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: List.generate(
                              dates.length,
                              (i) => Expanded(
                                child: Column(
                                  children: [
                                    SizedBox(
                                      height: 150,
                                      child: Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.end,
                                        children: [
                                          for (final bar in [
                                            (
                                              debtBuckets[i],
                                              AppColors.debt,
                                              'ديون',
                                            ),
                                            (
                                              paymentBuckets[i],
                                              AppColors.payment,
                                              'دفعات',
                                            ),
                                          ])
                                            Tooltip(
                                              triggerMode:
                                                  TooltipTriggerMode.tap,
                                              message:
                                                  '${bar.$3}: ${money(bar.$1)} $currency',
                                              child: Container(
                                                width: 12,
                                                height: bar.$1 == 0
                                                    ? 2
                                                    : math.max(
                                                        4.0,
                                                        144 * bar.$1 / peak,
                                                      ),
                                                margin:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 2,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: bar.$2.withValues(
                                                    alpha: bar.$1 == 0
                                                        ? .15
                                                        : 1,
                                                  ),
                                                  borderRadius:
                                                      const BorderRadius.vertical(
                                                        top: Radius.circular(4),
                                                      ),
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      DateFormat(
                                        monthly ? 'MM/yy' : 'd/M',
                                      ).format(dates[i]),
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: AppColors.textSecondary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                if (peak > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      'أعلى عمود: ${money(peak)} $currency • اضغط العمود لعرض المبلغ',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          section(
            'تحليل العملاء',
            'حالة الأرصدة • افتح البطاقات لعرض التفاصيل',
          ),
          panel(
            'حالة العملاء',
            'العملاء ذوو الحركة في الفترة • أرصدتهم حتى نهايتها',
            Column(
              children: [
                SizedBox(
                  width: 144,
                  height: 144,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Positioned.fill(
                        child: CustomPaint(
                          painter: _CustomerRing([owing, settled, prepaid]),
                        ),
                      ),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '${customers.length}',
                            style: const TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w800,
                              color: AppColors.textPrimary,
                            ),
                          ),
                          const Text(
                            'عميل',
                            style: TextStyle(color: AppColors.textSecondary),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 16,
                  runSpacing: 10,
                  alignment: WrapAlignment.center,
                  children: [
                    legend('مديونون $owing', AppColors.debt),
                    legend('دون مديونية $settled', AppColors.settled),
                    legend('رصيد مقدم $prepaid', AppColors.customerCredit),
                  ],
                ),
              ],
            ),
          ),
          panel(
            'أعلى الأرصدة المستحقة',
            'أعلى ٥ عملاء ذوي حركة في الفترة • الرصيد حتى نهايتها',
            top.isEmpty
                ? const Text(
                    'لا توجد أرصدة مستحقة للعملاء المحددين حتى نهاية الفترة',
                    style: TextStyle(color: AppColors.textSecondary),
                  )
                : Column(
                    children: top.take(5).map((c) {
                      final value = balances[c['id']]!;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: Column(
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    c['name'].toString(),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Flexible(
                                  child: Text(
                                    '${money(value)} $currency',
                                    style: const TextStyle(
                                      color: AppColors.debt,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 7),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: LinearProgressIndicator(
                                value: value / balances[top.first['id']]!,
                                minHeight: 5,
                                color: AppColors.debt,
                                backgroundColor: AppColors.debt.withValues(
                                  alpha: .08,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
          ),
          panel(
            'العمليات حسب التصنيف',
            'إجماليات الفترة المختارة • $currency',
            sortedCategories.isEmpty
                ? const Text(
                    'لا توجد عمليات مصنفة في هذه الفترة',
                    style: TextStyle(color: AppColors.textSecondary),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: sortedCategories
                        .map(
                          (c) => Padding(
                            padding: const EdgeInsets.only(bottom: 14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  c.key,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.textPrimary,
                                  ),
                                ),
                                const SizedBox(height: 5),
                                Wrap(
                                  spacing: 14,
                                  runSpacing: 4,
                                  children: [
                                    for (final item in [
                                      ('ديون', c.value[0], AppColors.debt),
                                      ('دفعات', c.value[1], AppColors.payment),
                                      (
                                        'خصومات',
                                        c.value[2],
                                        AppColors.discount,
                                      ),
                                    ])
                                      if (item.$2 > 0)
                                        Text(
                                          '${item.$1}: ${money(item.$2)}',
                                          style: TextStyle(
                                            color: item.$3,
                                            fontSize: 13,
                                          ),
                                        ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        )
                        .toList(),
                  ),
          ),
          Theme(
            data: Theme.of(
              context,
            ).copyWith(dividerColor: AppColors.transparent),
            child: const ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.only(bottom: 16),
              title: Text(
                'كيف تُحسب أرقام التقرير؟',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textSecondary,
                ),
              ),
              children: [
                Text(
                  'تشمل البطاقات والرسوم العملاء ذوي الحركة في الفترة المختارة. أرصدتهم محسوبة حتى نهاية الفترة وتشمل الرصيد السابق. تستبعد إحصاءات الحركة القيود المعكوسة حتى ذلك التاريخ. صافي الحركة = الديون − الدفعات − الخصومات؛ لا يمثل الرصيد الختامي.',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                    height: 1.6,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CustomerRing extends CustomPainter {
  _CustomerRing(this.values);
  final List<int> values;
  @override
  void paint(Canvas canvas, Size size) {
    final total = values.fold<int>(0, (a, b) => a + b);
    final rect = Offset.zero & size;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 13;
    canvas.drawOval(rect.deflate(9), paint..color = AppColors.borderLight);
    if (total == 0) return;
    var angle = -math.pi / 2;
    const colors = [
      AppColors.debt,
      AppColors.settled,
      AppColors.customerCredit,
    ];
    for (var i = 0; i < values.length; i++) {
      final sweep = values[i] / total * math.pi * 2;
      if (sweep > 0) {
        canvas.drawArc(
          rect.deflate(9),
          angle,
          sweep,
          false,
          paint..color = colors[i],
        );
      }
      angle += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _CustomerRing oldDelegate) =>
      !listEquals(values, oldDelegate.values);
}
