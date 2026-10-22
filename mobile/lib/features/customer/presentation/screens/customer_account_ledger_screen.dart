import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_icons.dart';
import '../../../../app/router/app_routes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../auth/presentation/controllers/auth_controller.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import '../../data/customer_ledger_pdf.dart';
import '../../../../shared/widgets/top_notice.dart';
import '../../data/customer_repository.dart';
import '../../data/customer_cache.dart';
import '../../data/customer_local_store.dart';
import 'customer_entry_details_screen.dart';
import '../../data/models/customer_summary_model.dart';

class CustomerAccountLedgerScreen extends ConsumerStatefulWidget {
  final CustomerBusinessSummary summary;
  final CustomerRepository? repository;
  final String? focusEntryId;
  const CustomerAccountLedgerScreen({
    super.key,
    required this.summary,
    this.repository,
    this.focusEntryId,
  });
  @override
  ConsumerState<CustomerAccountLedgerScreen> createState() =>
      _CustomerAccountLedgerScreenState();
}

class _CustomerAccountLedgerScreenState
    extends ConsumerState<CustomerAccountLedgerScreen> {
  late final _repository = widget.repository ?? CustomerRepository();
  final _cache = CustomerCache();
  final _rows = <Map<String, dynamic>>[];
  late final String? _owner = _repository.userId;
  bool _busy = false, _more = true, _cached = false;
  String? _error, _updated;
  int _offset = 0;
  bool _exporting = false;
  String _filter = 'all';
  String _query = '';
  late CustomerBusinessSummary _displaySummary = widget.summary;
  bool _refreshing = false;

  Future<void> _exportPdf() async {
    if (_exporting || _busy || !_current) return;
    setState(() => _exporting = true);
    try {
      final snapshot =
          await _repository.local.ledger(
            _owner!,
            widget.summary.businessCustomerId,
            widget.summary.currencyCode,
          ) ??
          await _repository.fetchCompleteLedger(
            businessCustomerId: widget.summary.businessCustomerId,
            currency: widget.summary.currencyCode,
          );
      if (!_current) return;
      final summary = snapshot.summaries.single;
      final bytes = await customerLedgerPdf(
        summary: summary,
        entries: snapshot.entries,
        updatedAt: snapshot.updatedAt,
        isComplete: true,
      );
      if (!mounted || !_current) return;
      final box = context.findRenderObject() as RenderBox?;
      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile.fromData(
              bytes,
              mimeType: 'application/pdf',
              name: 'customer-statement.pdf',
            ),
          ],
          fileNameOverrides: ['customer-statement.pdf'],
          sharePositionOrigin: box == null
              ? null
              : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
    } catch (e) {
      if (mounted) {
        TopNotice.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'تعذر تحميل الكشف الكامل. تحقق من الاتصال وأعد التصدير.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  String get _key =>
      'ledger:${widget.summary.businessCustomerId}:${widget.summary.currencyCode}';
  bool get _current =>
      mounted && _owner != null && _owner == _repository.userId;

  @override
  void initState() {
    super.initState();
    CustomerLocalStore.ledgerChanges.addListener(_restoreSyncedLedger);
    _load(reset: true);
  }

  @override
  void dispose() {
    CustomerLocalStore.ledgerChanges.removeListener(_restoreSyncedLedger);
    super.dispose();
  }

  Future<void> _restoreSyncedLedger() async {
    if (!_current || _busy) return;
    try {
      final saved = await _repository.local.ledger(
        _owner!,
        widget.summary.businessCustomerId,
        widget.summary.currencyCode,
      );
      if (!_current || _busy || saved == null) return;
      if (_updated != null &&
          DateTime.parse(saved.updatedAt).isBefore(DateTime.parse(_updated!))) {
        return;
      }
      setState(() {
        _rows
          ..clear()
          ..addAll(saved.entries);
        _displaySummary = saved.summaries.single;
        _updated = saved.updatedAt;
        _more = false;
        _cached = true;
      });
    } catch (_) {
      /* Keep the visible, complete projection. */
    }
  }

  Future<void> _load({bool reset = false}) async {
    if (_busy || !_current) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    // A complete downloaded ledger supports all history/search/export offline.
    try {
      final local = await _repository.local.ledger(
        _owner!,
        widget.summary.businessCustomerId,
        widget.summary.currencyCode,
      );
      if (!_current) return;
      if (local != null) {
        setState(() {
          _rows
            ..clear()
            ..addAll(local.entries);
          _updated = local.updatedAt;
          _displaySummary = local.summaries.single;
          _cached = true;
          _more = false;
          _busy = false;
        });
        if (reset) _refreshCompleteLedger();
        return;
      }
    } catch (_) {
      /* Retain legacy cache for the first upgrade. */
    }
    if (reset && _rows.isEmpty) {
      try {
        final saved = await _cache.read(_owner!, _key);
        if (!_current) return;
        if (saved != null) {
          setState(() {
            _rows.addAll(
              List<Map<String, dynamic>>.from(saved['rows'] as List),
            );
            _updated = saved['updated_at'] as String?;
            _cached = true;
          });
        }
      } catch (_) {
        /* Cache failure does not prevent fetching. */
      }
    }
    try {
      final page = await _repository.fetchLedgerPage(
        businessCustomerId: widget.summary.businessCustomerId,
        currency: widget.summary.currencyCode,
        offset: reset ? 0 : _offset,
      );
      if (!_current) return;
      setState(() {
        if (reset) {
          _rows.clear();
          _offset = 0;
        }
        final existing = _rows.map((e) => e['id']).toSet();
        _rows.addAll(page.where((e) => existing.add(e['id'])));
        _offset += page.length;
        _more = page.length == 50;
        _cached = false;
        _updated = DateTime.now().toUtc().toIso8601String();
      });
      try {
        await _cache.write(_owner!, _key, {
          'rows': _rows,
          'updated_at': _updated,
        });
      } catch (_) {}
    } catch (e) {
      if (_current) {
        setState(() {
          _error = _repository.friendlyError(e);
          _cached = _rows.isNotEmpty;
        });
      }
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  Future<void> _refreshCompleteLedger() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final snapshot = await _repository.fetchCompleteLedger(
        businessCustomerId: widget.summary.businessCustomerId,
        currency: widget.summary.currencyCode,
      );
      if (!_current) return;
      await _repository.local.saveLedger(
        _owner!,
        snapshot,
        relationship: widget.summary.businessCustomerId,
        currency: widget.summary.currencyCode,
      );
      if (!_current) return;
      setState(() {
        _rows
          ..clear()
          ..addAll(snapshot.entries);
        _updated = snapshot.updatedAt;
        _displaySummary = snapshot.summaries.single;
        _cached = false;
        _more = false;
      });
    } catch (_) {
      /* The last complete ledger remains available offline. */
    } finally {
      _refreshing = false;
    }
  }

  Widget _balanceAmount({
    required String label,
    required double amount,
    required Color color,
    required NumberFormat formatter,
  }) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    decoration: BoxDecoration(
      color: AppColors.white.withValues(alpha: .10),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 12, color: AppColors.white70),
        ),
        const SizedBox(height: 5),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: AlignmentDirectional.centerStart,
          child: Text(
            '\u2066${formatter.format(amount)}\u2069 ${widget.summary.currencyCode}',
            maxLines: 1,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (widget.repository == null) {
      ref.watch(authControllerProvider.select((auth) => auth.userId));
    }
    if (!_current) {
      return const Scaffold(
        body: Center(child: Text('تغير الحساب. افتح السجل من حسابك الحالي.')),
      );
    }
    const types = {
      'debt': 'دين',
      'payment': 'دفعة',
      'discount': 'خصم',
      'reversal': 'عكس',
    };
    final formatter = NumberFormat('#,##0.####');
    return Scaffold(
      backgroundColor: AppColors.backgroundLight,
      appBar: AppBar(
        backgroundColor: AppColors.backgroundLight,
        elevation: 0,
        toolbarHeight: 60,
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.summary.businessName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 2),
            Text(
              'كشف الحساب • ${widget.summary.currencyCode}',
              style: const TextStyle(
                fontSize: 11,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: _exporting ? 'جارٍ تجهيز الكشف' : 'تصدير الكشف الكامل PDF',
            onPressed: _busy || _exporting ? null : _exportPdf,
            icon: _exporting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.picture_as_pdf_outlined, size: 22),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _load(reset: true),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                gradient: AppColors.cardGradient,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'رصيد حسابك',
                    style: TextStyle(fontSize: 12, color: AppColors.white70),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: _balanceAmount(
                          label: 'عليك',
                          amount: _displaySummary.currentBalance > 0
                              ? _displaySummary.currentBalance
                              : 0,
                          color: const Color(0xFFFFD7D4),
                          formatter: formatter,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _balanceAmount(
                          label: 'لك',
                          amount: _displaySummary.currentBalance < 0
                              ? _displaySummary.currentBalance.abs()
                              : 0,
                          color: const Color(0xFFD3F5E5),
                          formatter: formatter,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'صافي الرصيد حسب آخر ملخص محفوظ',
                    style: TextStyle(fontSize: 10, color: AppColors.white70),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'حركات الحساب',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                hintText: 'ابحث في وصف الحركات المحمّلة',
                prefixIcon: const Icon(Icons.search, size: 20),
                filled: true,
                fillColor: AppColors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: AppColors.borderLight),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: AppColors.borderLight),
                ),
              ),
              onChanged: (value) =>
                  setState(() => _query = value.trim().toLowerCase()),
            ),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                spacing: 6,
                children: [
                  for (final option in const {
                    'all': 'الكل',
                    'debt': 'الديون',
                    'payment': 'الدفعات',
                    'discount': 'الخصومات',
                  }.entries)
                    ChoiceChip(
                      label: Text(
                        option.value,
                        style: const TextStyle(fontSize: 12),
                      ),
                      showCheckmark: false,
                      selectedColor: AppColors.primaryContainer,
                      side: BorderSide.none,
                      visualDensity: VisualDensity.compact,
                      selected: _filter == option.key,
                      onSelected: (_) => setState(() => _filter = option.key),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            if (_updated != null)
              Text(
                '${_cached ? 'نسخة الجهاز • آخر مزامنة' : 'آخر تحديث'}: ${DateFormat('yyyy/MM/dd HH:mm').format(DateTime.parse(_updated!).toLocal())}',
                style: const TextStyle(
                  fontSize: 10,
                  color: AppColors.textMuted,
                ),
              ),
            if (_error != null) ...[
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              TextButton(
                onPressed: _busy ? null : () => _load(reset: true),
                child: const Text('تحديث من الخادم'),
              ),
            ],
            if (widget.focusEntryId != null && _rows.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: .08),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.notifications_active_outlined, size: 20),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'تم فتح الحساب المرتبط بالإشعار. الحركة المعنية مميزة أدناه إن كانت ضمن القائمة.',
                      ),
                    ),
                  ],
                ),
              ),
            if (!_busy && _rows.isEmpty && _error == null)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Text('لا توجد حركات بهذه العملة.'),
              ),
            ..._rows
                .where(
                  (row) =>
                      (_filter == 'all' || row['entry_type'] == _filter) &&
                      (row['description'] ?? '')
                          .toString()
                          .toLowerCase()
                          .contains(_query),
                )
                .map((row) {
                  final entry = CustomerPendingEntry.fromMap(row);
                  final focused = row['id'] == widget.focusEntryId;
                  return Card(
                    elevation: 0,
                    margin: const EdgeInsets.only(top: 6),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    color: focused
                        ? AppColors.primary.withValues(alpha: .08)
                        : AppColors.white,
                    child: ListTile(
                      onTap: () => Navigator.push(
                        context,
                        AppRoutes.accountPage(
                          builder: (_) => CustomerEntryDetailsScreen(
                            ownerId: _owner,
                            businessName: widget.summary.businessName,
                            entry: Map<String, dynamic>.from(row),
                          ),
                        ),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 2,
                      ),
                      dense: true,
                      minLeadingWidth: 28,
                      horizontalTitleGap: 8,
                      trailing: const Icon(Icons.chevron_left, size: 18),
                      leading: CircleAvatar(
                        radius: 15,
                        backgroundColor: AppColors.transactionColor(
                          entry.entryType,
                        ).withValues(alpha: .10),
                        child: Icon(
                          AppIcons.transaction(entry.entryType),
                          size: 16,
                          color: AppColors.transactionColor(entry.entryType),
                        ),
                      ),
                      title: Row(
                        children: [
                          Expanded(
                            child: Text(
                              types[entry.entryType] ?? entry.entryType,
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              '\u2066${formatter.format(entry.amount)}\u2069 ${entry.currencyCode}',
                              textAlign: TextAlign.end,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: entry.direction == 'debit'
                                    ? AppColors.debtRed
                                    : AppColors.paymentGreen,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
            if (_busy) const Center(child: CircularProgressIndicator()),
            if (!_busy && _more && !_cached && _error == null)
              OutlinedButton(
                onPressed: () => _load(),
                child: const Text('تحميل حركات أقدم'),
              ),
          ],
        ),
      ),
    );
  }
}
