import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_icons.dart';
import '../../../core/database/app_database.dart';
import '../../../core/sync/sync_engine.dart';
import '../../../core/sync/sync_policy.dart';

/// قائمة صريحة ودائمة للأوامر التي رفضها الخادم.
/// لا تُحذف أي عملية مالية من هذه الشاشة؛ يمكن تصحيح السبب ثم إعادة المحاولة.
class RejectedOperationsScreen extends StatefulWidget {
  const RejectedOperationsScreen({super.key, this.loadOperations});

  final Future<List<Map<String, dynamic>>> Function()? loadOperations;

  @override
  State<RejectedOperationsScreen> createState() =>
      _RejectedOperationsScreenState();
}

class _RejectedOperationsScreenState extends State<RejectedOperationsScreen> {
  late Future<List<Map<String, dynamic>>> _operations;

  @override
  void initState() {
    super.initState();
    _operations = _load();
  }

  Future<List<Map<String, dynamic>>> _load() =>
      widget.loadOperations?.call() ??
      AppDatabase.instance.getDeadLetterMutations();

  void _refresh() => setState(() => _operations = _load());

  Future<void> _retry(String requestId) async {
    await AppDatabase.instance.retryDeadLetterMutation(requestId);
    await SyncEngine.instance.triggerSync();
    if (mounted) _refresh();
  }

  Future<void> _discard(String requestId) async {
    await AppDatabase.instance.discardDeadLetterMutation(requestId);
    if (mounted) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('عمليات رفضها الخادم')),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _operations,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Text('تعذر قراءة العمليات: ${snapshot.error}'),
            );
          }
          final rows = snapshot.data ?? const [];
          if (rows.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(AppIcons.synced, color: AppColors.success, size: 52),
                    SizedBox(height: 12),
                    Text('لا توجد عمليات مرفوضة'),
                  ],
                ),
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: () async => _refresh(),
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: rows.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, index) => _RejectedOperationCard(
                operation: rows[index],
                onRetry: _retry,
                onDiscard: _discard,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _RejectedOperationCard extends StatelessWidget {
  const _RejectedOperationCard({
    required this.operation,
    required this.onRetry,
    required this.onDiscard,
  });

  final Map<String, dynamic> operation;
  final Future<void> Function(String requestId) onRetry;
  final Future<void> Function(String requestId) onDiscard;

  @override
  Widget build(BuildContext context) {
    final requestId = operation['client_request_id'] as String;
    final command = operation['command_type'] as String? ?? 'unknown';
    final payload = _payload(operation['payload_json']);
    final amount = payload['p_amount'] ?? payload['amount'];
    final currency = payload['p_currency_code'] ?? payload['currencyCode'];
    final error = operation['last_error'] as String? ?? 'رفض الخادم العملية';
    final code = operation['last_error_code'] as String?;
    return Card(
      color: AppColors.errorLight,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(AppIcons.warning, color: AppColors.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _label(command),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                if (amount != null)
                  Text('${amount.toString()} ${currency ?? ''}'.trim()),
              ],
            ),
            const SizedBox(height: 10),
            Text(error, maxLines: 4, overflow: TextOverflow.ellipsis),
            if (code != null) ...[
              const SizedBox(height: 4),
              Text(
                'رمز الخطأ: $code',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (canDiscardSyncCommand(command))
                  TextButton(
                    onPressed: () => _confirmDiscard(context, requestId),
                    child: const Text('تجاهل العملية'),
                  ),
                FilledButton.icon(
                  onPressed: () => onRetry(requestId),
                  icon: const Icon(AppIcons.sync),
                  label: const Text('إعادة المحاولة'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDiscard(BuildContext context, String requestId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('تجاهل عملية غير مالية؟'),
        content: const Text(
          'سيُحذف طلب المزامنة فقط. لا يمكن تنفيذ هذا الإجراء للقيود المالية أو الأنواع غير المعروفة.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('تجاهل'),
          ),
        ],
      ),
    );
    if (confirmed == true) await onDiscard(requestId);
  }

  static Map<String, dynamic> _payload(dynamic raw) {
    try {
      return jsonDecode(raw as String) as Map<String, dynamic>;
    } catch (_) {
      return const {};
    }
  }

  static String _label(String command) => switch (command) {
    'create_ledger_entry' => 'قيد مالي مرفوض',
    'apply_customer_discount' => 'خصم مرفوض',
    'reverse_ledger_entry' => 'عكس قيد مرفوض',
    'customer_directory' => 'إضافة عميل مرفوضة',
    _ => 'عملية مرفوضة ($command)',
  };
}
