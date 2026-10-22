import 'package:muthbat/shared/widgets/top_notice.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../features/auth/presentation/controllers/auth_controller.dart';
import '../../data/models/dispute_message_model.dart';
import '../../data/models/dispute_model.dart';
import '../controllers/merchant_controller.dart';
import '../widgets/resolve_dispute_sheet.dart';
import 'dart:async';
import 'dart:convert';
import '../../../../app/router/app_routes.dart';
import '../../../../core/sync/sync_engine.dart';

class DisputeDetailScreen extends ConsumerStatefulWidget {
  final DisputeModel dispute;

  const DisputeDetailScreen({super.key, required this.dispute});

  @override
  ConsumerState<DisputeDetailScreen> createState() =>
      _DisputeDetailScreenState();
}

class _DisputeDetailScreenState extends ConsumerState<DisputeDetailScreen> {
  late DisputeModel _dispute;
  List<DisputeMessageModel> _messages = [];
  bool _isLoadingMessages = true;
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  bool _isSending = false;
  bool _resolutionPending = false;
  Map<String, dynamic>? _decisionQueue;
  String? _localError;
  int _loadVersion = 0;
  StreamSubscription<SyncProgress>? _syncSubscription;

  @override
  void initState() {
    super.initState();
    _dispute = widget.dispute;
    _loadMessages();
    _syncSubscription = SyncEngine.instance.progressStream.listen((p) {
      if (mounted &&
          (p.state == SyncState.synced ||
              p.state == SyncState.error ||
              p.state == SyncState.idle)) {
        _loadMessages(silent: true);
      }
    });
  }

  @override
  void dispose() {
    _messageController.dispose();
    _syncSubscription?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadMessages({bool silent = false}) async {
    final version = ++_loadVersion;
    if (!silent && _messages.isEmpty) setState(() => _isLoadingMessages = true);
    try {
      final repo = ref.read(merchantRepositoryProvider);
      final list = await repo.getDisputeMessages(_dispute.id);
      final pending = await repo.getDisputeResolutionQueue(_dispute.id);
      final disputes = await repo.getCachedDisputes(_dispute.businessId);
      if (mounted && version == _loadVersion) {
        setState(() {
          _messages = list;
          _resolutionPending = pending != null;
          _decisionQueue = pending;
          _localError = null;
          _dispute =
              disputes.where((d) => d.id == _dispute.id).firstOrNull ??
              _dispute;
          _isLoadingMessages = false;
        });
        _scrollToBottom();
      }
    } catch (_) {
      if (mounted && version == _loadVersion) {
        setState(() {
          _isLoadingMessages = false;
          _localError = 'تعذر قراءة تفاصيل الاعتراض. أعد المحاولة.';
        });
      }
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty || _isSending || _resolutionPending || !_dispute.isOpen) {
      return;
    }

    setState(() => _isSending = true);
    try {
      final success = await ref
          .read(merchantControllerProvider.notifier)
          .sendDisputeMessage(_dispute.id, text);

      if (mounted) {
        setState(() => _isSending = false);
        if (success) {
          _messageController.clear();
          await _loadMessages();
        } else {
          TopNotice.of(context).showSnackBar(
            const SnackBar(
              content: Text('تعذر حفظ الرسالة. حاول مجددًا.'),
              backgroundColor: AppColors.error,
            ),
          );
        }
      }
    } catch (_) {
      if (mounted) {
        TopNotice.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'تعذر حفظ الرسالة؛ ما زال نصك موجودًا للمحاولة مجددًا.',
            ),
            backgroundColor: AppColors.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  void _openResolveSheet() async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.transparent,
      builder: (_) => ResolveDisputeSheet(dispute: _dispute),
    );

    if (result == true && mounted) {
      final updatedList = await ref
          .read(merchantRepositoryProvider)
          .getDisputes(_dispute.businessId);
      final updated = updatedList.firstWhere(
        (d) => d.id == _dispute.id,
        orElse: () => _dispute,
      );
      if (mounted) {
        setState(() => _dispute = updated);
        await _loadMessages();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final currencyFormatter = NumberFormat('#,##0.##');
    final failedDecision = _decisionQueue?['status'] == 'dead_letter';
    final decision = _decisionQueue == null
        ? null
        : jsonDecode(_decisionQueue!['payload_json'] as String) as Map;
    final decisionLabel = switch (decision?['p_resolution']) {
      'accepted' => 'قبول الاعتراض',
      'partially_accepted' => 'تصحيح المبلغ',
      'rejected' => 'رفض الاعتراض',
      _ => 'القرار',
    };

    Color statusColor;
    switch (_dispute.status) {
      case 'awaiting_merchant':
        statusColor = AppColors.debtRed;
        break;
      case 'awaiting_customer':
        statusColor = AppColors.warning;
        break;
      case 'accepted':
        statusColor = AppColors.success;
        break;
      case 'partially_accepted':
        statusColor = AppColors.accentGoldDark;
        break;
      case 'rejected':
        statusColor = AppColors.textSecondary;
        break;
      default:
        statusColor = AppColors.info;
    }

    return Scaffold(
      resizeToAvoidBottomInset: true,
      backgroundColor: AppColors.backgroundLight,
      appBar: AppBar(
        backgroundColor: AppColors.primaryDark,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'تفاصيل الاعتراض',
              style: AppTypography.titleMedium(color: AppColors.white),
            ),
            Text(
              _dispute.customerDisplayName ?? 'معاملة مالية',
              style: AppTypography.caption(color: AppColors.accentGold),
            ),
          ],
        ),
        actions: [
          if (_dispute.isOpen && !_resolutionPending)
            TextButton.icon(
              onPressed: _openResolveSheet,
              icon: const Icon(
                Icons.gavel_rounded,
                size: 18,
                color: AppColors.accentGold,
              ),
              label: const Text(
                'اتخاذ قرار',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: AppColors.accentGold,
                ),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          if (_resolutionPending)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              color: failedDecision
                  ? AppColors.warningLight
                  : AppColors.primaryContainer,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    failedDecision
                        ? 'تعذر اعتماد القرار'
                        : '$decisionLabel • محفوظ على الجهاز',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      color: AppColors.primaryDark,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    failedDecision
                        ? 'القرار لم يُعتمد. افتح مراجعة الإرسال لمعرفة السبب وإعادة المحاولة.'
                        : 'سيُرسل تلقائيًا. لم تُعتمد النتيجة بعد؛ لا تحتاج إلى اتخاذ القرار مرة أخرى.',
                    style: const TextStyle(fontSize: 12, height: 1.6),
                  ),
                  if (failedDecision)
                    TextButton(
                      onPressed: () => Navigator.pushNamed(
                        context,
                        AppRoutes.rejectedOperations,
                      ),
                      child: const Text('مراجعة الإرسال'),
                    ),
                ],
              ),
            ),
          if (_localError != null)
            TextButton(onPressed: _loadMessages, child: Text(_localError!)),
          // 1. بطاقة تفاصيل القيد والنزاع المثبتة في الأعلى
          Container(
            padding: const EdgeInsets.all(16),
            decoration: const BoxDecoration(
              color: AppColors.white,
              border: Border(bottom: BorderSide(color: AppColors.borderLight)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 12,
                  runSpacing: 10,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: AppColors.debtRed.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Icon(
                            Icons.warning_amber_rounded,
                            color: AppColors.debtRed,
                            size: 16,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _dispute.reasonLocalized,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ],
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        _resolutionPending
                            ? (failedDecision ? 'تحتاج مراجعة' : 'قرار محفوظ')
                            : _dispute.statusLocalized,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: statusColor,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                if (_dispute.description.isNotEmpty)
                  Text(
                    'ملاحظة العميل: "${_dispute.description}"',
                    style: AppTypography.bodySmall(
                      color: AppColors.textSecondary,
                    ),
                  ),
                const Divider(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 6,
                  children: [
                    if (_dispute.entryAmount != null)
                      Text(
                        'المبلغ الأصلي: ${currencyFormatter.format(_dispute.entryAmount)} ${_dispute.currencyCode ?? ref.read(merchantControllerProvider).currency}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          color: AppColors.primary,
                        ),
                      ),
                    if (_dispute.createdAt != null)
                      Text(
                        'تاريخ الفتح: ${DateFormat('yyyy/MM/dd - hh:mm a').format(DateTime.parse(_dispute.createdAt!))}',
                        style: AppTypography.caption(
                          color: AppColors.textSecondary,
                        ),
                      ),
                  ],
                ),
                if (_dispute.isResolved && _dispute.resolutionNote != null) ...[
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: statusColor.withValues(alpha: 0.2),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'قرار المعالجة (${_dispute.statusLocalized}):',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: statusColor,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _dispute.resolutionNote!,
                          style: AppTypography.caption(
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),

          // 2. سجل الرسائل والمحادثة
          Expanded(
            child: _isLoadingMessages
                ? const Center(
                    child: CircularProgressIndicator(color: AppColors.primary),
                  )
                : _messages.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.chat_bubble_outline_rounded,
                          size: 48,
                          color: AppColors.textSecondary.withValues(alpha: 0.4),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'لا توجد رسائل بعد',
                          style: AppTypography.titleSmall(
                            color: AppColors.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'يمكنك مراسلة العميل لتوضيح سبب القيد والوصول لحل.',
                          style: AppTypography.caption(
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(16),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final msg = _messages[index];
                      final currentUserId = ref
                          .read(authControllerProvider)
                          .userId;
                      final isMine =
                          msg.senderWorkspace == 'merchant' ||
                          (msg.senderWorkspace == null &&
                              msg.senderUserId == currentUserId);

                      return Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        alignment: isMine
                            ? AlignmentDirectional.centerStart
                            : AlignmentDirectional.centerEnd,
                        child: Container(
                          constraints: BoxConstraints(
                            maxWidth: MediaQuery.of(context).size.width * 0.78,
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: isMine
                                ? AppColors.primary
                                : AppColors.primaryContainer,
                            borderRadius: BorderRadiusDirectional.only(
                              topStart: const Radius.circular(16),
                              topEnd: const Radius.circular(16),
                              bottomStart: Radius.circular(isMine ? 4 : 16),
                              bottomEnd: Radius.circular(isMine ? 16 : 4),
                            ),
                            border: isMine
                                ? null
                                : Border.all(color: AppColors.borderLight),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (!isMine && msg.senderName != null) ...[
                                Text(
                                  msg.senderName!,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.accentGoldDark,
                                  ),
                                ),
                                const SizedBox(height: 4),
                              ],
                              Text(
                                msg.message,
                                style: TextStyle(
                                  color: isMine
                                      ? AppColors.white
                                      : AppColors.textPrimary,
                                  fontSize: 14,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                DateFormat(
                                  'hh:mm a',
                                ).format(DateTime.parse(msg.createdAt)),
                                style: TextStyle(
                                  color: isMine
                                      ? AppColors.white60
                                      : AppColors.textSecondary,
                                  fontSize: 10,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ).animate().fadeIn(duration: 150.ms);
                    },
                  ),
          ),

          // 3. شريط كتابة الرسالة (إذا كان النزاع مفتوحاً)
          if (_dispute.isOpen && !_resolutionPending)
            Container(
              padding: const EdgeInsets.only(
                left: 16,
                right: 16,
                top: 8,
                bottom: 8,
              ),
              decoration: const BoxDecoration(
                color: AppColors.white,
                border: Border(top: BorderSide(color: AppColors.borderLight)),
              ),
              child: SafeArea(
                top: false,
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _messageController,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _sendMessage(),
                        decoration: InputDecoration(
                          hintText: 'اكتب ردك للعميل...',
                          filled: true,
                          fillColor: AppColors.backgroundLight,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(24),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      onPressed: _isSending ? null : _sendMessage,
                      icon: _isSending
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: AppColors.white,
                              ),
                            )
                          : const Icon(Icons.send_rounded, size: 20),
                      style: IconButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: AppColors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
