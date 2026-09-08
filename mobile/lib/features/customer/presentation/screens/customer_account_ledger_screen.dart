import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../auth/presentation/controllers/auth_controller.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import '../../data/customer_ledger_pdf.dart';
import '../../../../shared/widgets/top_notice.dart';
import '../../data/customer_repository.dart';
import '../../data/customer_cache.dart';
import '../../data/models/customer_summary_model.dart';

class CustomerAccountLedgerScreen extends ConsumerStatefulWidget {
  final CustomerBusinessSummary summary;
  final CustomerRepository? repository;
  const CustomerAccountLedgerScreen({
    super.key,
    required this.summary,
    this.repository,
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

  Future<void> _exportPdf() async {
    if (_exporting || _busy || _rows.isEmpty || !_current) return;
    setState(() => _exporting = true);
    try {
      final bytes = await customerLedgerPdf(
        summary: widget.summary,
        entries: List<Map<String, dynamic>>.from(_rows),
        updatedAt: _updated ?? 'غير معروف',
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
          const SnackBar(content: Text('تعذر تصدير الكشف. لم تتغير بياناتك.')),
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
    _load(reset: true);
  }

  Future<void> _load({bool reset = false}) async {
    if (_busy || !_current) return;
    setState(() {
      _busy = true;
      _error = null;
    });
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
      appBar: AppBar(
        title: Text(
          '${widget.summary.businessName} • ${widget.summary.currencyCode}',
        ),
      ),
      body: RefreshIndicator(
        onRefresh: () => _load(reset: true),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            OutlinedButton.icon(
              onPressed: _busy || _exporting || _rows.isEmpty
                  ? null
                  : _exportPdf,
              icon: const Icon(Icons.picture_as_pdf_outlined),
              label: Text(
                _exporting ? 'جارٍ إعداد الكشف…' : 'تصدير الحركات المحمّلة PDF',
              ),
            ),
            const Text(
              'حركات حسابك لدى البقالة',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const Text(
              'هذه قيود مالية وليست قائمة منتجات. تحميل المزيد يعرض الحركات الأقدم.',
            ),
            if (_updated != null)
              Text(
                '${_cached ? 'نسخة محفوظة — قد تكون قديمة' : 'آخر تحديث'}: ${DateFormat('yyyy/MM/dd HH:mm').format(DateTime.parse(_updated!).toLocal())}',
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
            if (!_busy && _rows.isEmpty && _error == null)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Text('لا توجد حركات بهذه العملة.'),
              ),
            ..._rows.map((row) {
              final entry = CustomerPendingEntry.fromMap(row);
              final reversed = row['is_reversed'] == true;
              final status = switch (row['confirmation_status']) {
                'confirmed' => 'مؤكدة',
                'pending' => 'بانتظار التأكيد',
                _ => 'غير متاح',
              };
              return Card(
                child: ListTile(
                  leading: Icon(
                    entry.direction == 'debit'
                        ? Icons.arrow_upward
                        : Icons.arrow_downward,
                  ),
                  title: Text(
                    '${types[entry.entryType] ?? entry.entryType} • ${formatter.format(entry.amount)} ${entry.currencyCode}',
                  ),
                  subtitle: Text(
                    '${entry.description}\n${entry.occurredAt}\n${reversed ? 'معكوسة • ' : ''}$status${row['dispute_status'] == 'open'
                        ? ' • اعتراض مفتوح'
                        : row['dispute_status'] == 'resolved'
                        ? ' • تمت معالجة الاعتراض'
                        : ''}',
                  ),
                  isThreeLine: true,
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
