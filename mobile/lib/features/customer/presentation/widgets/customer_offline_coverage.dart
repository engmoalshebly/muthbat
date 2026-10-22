import 'dart:async';
import 'package:flutter/material.dart';
import '../../data/customer_local_store.dart';

/// Distinguishes a downloaded home balance from fully downloaded statements.
class CustomerOfflineCoverage extends StatefulWidget {
  const CustomerOfflineCoverage({super.key, required this.owner});
  final String owner;
  @override
  State<CustomerOfflineCoverage> createState() =>
      _CustomerOfflineCoverageState();
}

class _CustomerOfflineCoverageState extends State<CustomerOfflineCoverage> {
  ({int ready, int total})? _coverage;
  int _version = 0;
  @override
  void initState() {
    super.initState();
    CustomerLocalStore.changes.addListener(_reload);
    CustomerLocalStore.ledgerChanges.addListener(_reload);
    _reload();
  }

  void _reload() => unawaited(_load());
  Future<void> _load() async {
    final version = ++_version;
    try {
      final coverage = await CustomerLocalStore().coverage(widget.owner);
      if (mounted && version == _version) setState(() => _coverage = coverage);
    } catch (_) {
      /* The next local write retries the status. */
    }
  }

  @override
  void didUpdateWidget(CustomerOfflineCoverage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.owner != widget.owner) {
      _coverage = null;
      _reload();
    }
  }

  @override
  void dispose() {
    CustomerLocalStore.changes.removeListener(_reload);
    CustomerLocalStore.ledgerChanges.removeListener(_reload);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final coverage = _coverage;
    if (coverage == null || coverage.total == 0) return const SizedBox.shrink();
    final ready = coverage.ready == coverage.total;
    return ListTile(
      dense: true,
      leading: Icon(
        ready ? Icons.offline_pin_outlined : Icons.cloud_download_outlined,
      ),
      title: Text(
        ready
            ? 'كشوفك محفوظة للقراءة دون إنترنت'
            : 'كشوف محفوظة على الجهاز: ${coverage.ready} من ${coverage.total}',
      ),
      subtitle: ready
          ? null
          : const Text(
              'يكتمل التنزيل تلقائيًا عند الاتصال. انتظر اكتماله قبل العمل دون إنترنت.',
            ),
    );
  }
}
