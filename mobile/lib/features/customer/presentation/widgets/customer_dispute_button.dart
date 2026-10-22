import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/services/push_notification_service.dart';
import '../controllers/customer_controller.dart';
import '../../data/customer_outbox.dart';
import '../../data/customer_disputes_repository.dart';
import '../screens/customer_disputes_screen.dart';
import '../../../../app/router/app_routes.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';

Future<bool> presentCustomerDispute(
  BuildContext context,
  WidgetRef ref, {
  required String entryId,
  String? ownerId,
  Map<String, dynamic>? entry,
  String? businessName,
}) async {
  final repository = ref.read(customerRepositoryProvider);
  final owner = repository.userId;
  if (owner == null || (ownerId != null && owner != ownerId)) return false;
  final request = await showDialog<({String reason, String description})>(
    context: context,
    builder: (_) => _DisputeDialog(entry: entry, businessName: businessName),
  );
  if (!context.mounted || request == null || repository.userId != owner) {
    return false;
  }
  try {
    await repository.openDispute(
      entryId: entryId,
      reason: request.reason,
      description: request.description,
    );
    if (!context.mounted || repository.userId != owner) return false;
    PushNotificationService.instance.changes.value++;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'طلبك محفوظ. سنرسله للتاجر عند توفر الإنترنت. تابع رده من «طلباتي للتاجر».',
        ),
      ),
    );
    return true;
  } catch (e) {
    if (context.mounted && repository.userId == owner) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(repository.friendlyError(e))));
    }
    return false;
  }
}

class CustomerDisputeButton extends ConsumerStatefulWidget {
  const CustomerDisputeButton({
    super.key,
    required this.entry,
    this.ownerId,
    this.businessName,
  });
  final Map<String, dynamic> entry;
  final String? ownerId;
  final String? businessName;
  @override
  ConsumerState<CustomerDisputeButton> createState() =>
      _CustomerDisputeButtonState();
}

class _CustomerDisputeButtonState extends ConsumerState<CustomerDisputeButton> {
  bool _busy = false, _queued = false;
  String? _disputeId, _status;
  Map<String, dynamic>? _failed;
  @override
  void initState() {
    super.initState();
    CustomerOutbox.changes.addListener(_reload);
    CustomerDisputesRepository.changes.addListener(_reload);
    _loadPending();
  }

  void _reload() {
    _loadPending();
  }

  @override
  void dispose() {
    CustomerOutbox.changes.removeListener(_reload);
    CustomerDisputesRepository.changes.removeListener(_reload);
    super.dispose();
  }

  Future<void> _loadPending() async {
    final repo = ref.read(customerRepositoryProvider);
    final owner = repo.userId;
    if (owner == null || (widget.ownerId != null && owner != widget.ownerId)) {
      return;
    }
    try {
      final pending = await repo.pendingActions();
      final disputes = await CustomerDisputesRepository().local(owner);
      if (mounted && repo.userId == owner) {
        setState(() {
          final dispute = disputes
              .where((d) => d['entry_id'] == widget.entry['id'])
              .firstOrNull;
          _disputeId = dispute?['id'] as String?;
          _status = dispute?['status'] as String?;
          _failed = pending
              .where(
                (a) =>
                    a['target_id'] == widget.entry['id'] &&
                    a['status'] == 'failed',
              )
              .firstOrNull;
          _queued = pending.any(
            (a) =>
                a['target_id'] == widget.entry['id'] &&
                a['status'] == 'pending',
          );
        });
      }
    } catch (_) {
      /* Submission will expose any local storage failure. */
    }
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    if (entry['id'] is! String) {
      return const SizedBox.shrink();
    }
    final active = {
      'open',
      'awaiting_merchant',
      'awaiting_customer',
      'escalated',
    }.contains(_status ?? entry['dispute_status']);
    if (_disputeId != null || active || _failed != null || _queued) {
      return OutlinedButton.icon(
        icon: const Icon(Icons.forum_outlined),
        label: Text(
          _failed != null
              ? 'لم يُرسل طلبك • اضغط للمحاولة'
              : _queued || active
              ? 'متابعة طلبك'
              : 'عرض رد التاجر',
        ),
        onPressed: () => Navigator.of(context).push(
          AppRoutes.accountPage(
            builder: (_) => CustomerDisputesScreen(
              disputeId: _disputeId,
              entryId: entry['id'] as String,
            ),
          ),
        ),
      );
    }
    if (entry['entry_type'] == 'reversal' ||
        entry['is_reversed'] == true ||
        entry['is_reversed'] == 1) {
      return const SizedBox.shrink();
    }
    return OutlinedButton.icon(
      icon: const Icon(Icons.report_problem_outlined),
      label: const Text('لدي مشكلة'),
      onPressed: _busy || _queued || active
          ? null
          : () async {
              setState(() => _busy = true);
              final saved = await presentCustomerDispute(
                context,
                ref,
                entryId: entry['id'] as String,
                ownerId: widget.ownerId,
                entry: entry,
                businessName: widget.businessName,
              );
              if (mounted) {
                setState(() {
                  _busy = false;
                  _queued = saved;
                });
              }
            },
    );
  }
}

class _DisputeDialog extends StatefulWidget {
  const _DisputeDialog({this.entry, this.businessName});
  final Map<String, dynamic>? entry;
  final String? businessName;
  @override
  State<_DisputeDialog> createState() => _DisputeDialogState();
}

class _DisputeDialogState extends State<_DisputeDialog> {
  final _form = GlobalKey<FormState>();
  final _description = TextEditingController();
  String _reason = 'wrong_amount';
  bool _describe = false;
  static const _reasons = {
    'wrong_amount': 'المبلغ غير صحيح',
    'unknown_transaction': 'لم أقم بهذه العملية',
    'duplicate': 'العملية مكررة',
    'already_paid': 'تم سدادها مسبقًا',
    'wrong_date': 'التاريخ غير صحيح',
    'wrong_description': 'الوصف غير صحيح',
    'other': 'سبب آخر',
  };
  @override
  void dispose() {
    _description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    backgroundColor: AppColors.white,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    title: Row(
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: AppColors.primaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Icon(
            Icons.edit_note_rounded,
            color: AppColors.primary,
            size: 24,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            _describe ? '٢. وضح للتاجر' : '١. ما المشكلة؟',
            style: AppTypography.titleMedium(color: AppColors.textPrimary),
          ),
        ),
      ],
    ),
    content: SingleChildScrollView(
      child: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.entry != null)
              Container(
                margin: const EdgeInsets.only(bottom: 14),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.backgroundLight,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.borderLight),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      widget.businessName ?? 'العملية المحددة',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${widget.entry!['amount']} ${widget.entry!['currency_code']}\n${widget.entry!['description'] ?? ''}\n${DateTime.tryParse(widget.entry!['occurred_at']?.toString() ?? '') == null ? '' : DateFormat('yyyy/MM/dd HH:mm').format(DateTime.parse(widget.entry!['occurred_at'] as String).toLocal())}',
                      style: const TextStyle(
                        height: 1.7,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            const Text(
              'سنطلب من التاجر مراجعة هذه العملية. يبقى المبلغ كما هو حتى يوافق على تغييره.',
              style: TextStyle(
                height: 1.7,
                fontSize: 13,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 16),
            if (!_describe)
              DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: _reason,
                decoration: InputDecoration(
                  labelText: 'اختر المشكلة',
                  filled: true,
                  fillColor: AppColors.backgroundLight,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                items: _reasons.entries
                    .map(
                      (r) =>
                          DropdownMenuItem(value: r.key, child: Text(r.value)),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value != null) _reason = value;
                },
              ),
            const SizedBox(height: 12),
            if (_describe) ...[
              Text(
                _reasons[_reason]!,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _description,
                minLines: 2,
                maxLines: 4,
                maxLength: 4000,
                decoration: InputDecoration(
                  labelText: 'ماذا تريد أن تقول للتاجر؟',
                  hintText: 'مثال: سجلت ٥٠٠٠ والصحيح ٥٠٠ فقط',
                  filled: true,
                  fillColor: AppColors.backgroundLight,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                validator: (value) => (value ?? '').trim().isEmpty
                    ? 'اكتب توضيحًا قصيرًا للتاجر'
                    : null,
              ),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () {
          if (_describe) {
            setState(() => _describe = false);
          } else {
            Navigator.pop(context);
          }
        },
        child: Text(_describe ? 'رجوع' : 'إلغاء'),
      ),
      FilledButton(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 13),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        onPressed: () {
          if (!_describe) {
            setState(() => _describe = true);
            return;
          }
          if (_form.currentState!.validate()) {
            Navigator.pop(context, (
              reason: _reason,
              description: _description.text.trim(),
            ));
          }
        },
        child: Text(_describe ? 'إرسال للتاجر' : 'التالي'),
      ),
    ],
  );
}
