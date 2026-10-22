import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/services/push_notification_service.dart';
import '../../data/customer_disputes_repository.dart';
import '../../data/customer_outbox.dart';
import '../../data/customer_repository.dart';

String simpleCustomerDisputeStatus(String? status) => switch (status) {
  'awaiting_customer' => 'التاجر يحتاج توضيحًا منك',
  'accepted' => 'وافق التاجر • أُلغي أثر العملية',
  'partially_accepted' => 'وافق التاجر • صُحح المبلغ',
  'rejected' => 'لم يوافق التاجر • المبلغ لم يتغير',
  'closed' => 'انتهى الطلب',
  _ => 'وصل طلبك • ننتظر رد التاجر',
};

class CustomerDisputesScreen extends StatefulWidget {
  const CustomerDisputesScreen({
    super.key,
    this.disputeId,
    this.entryId,
    this.repository,
    this.actions,
    this.refreshOnOpen = true,
  });
  final String? disputeId, entryId;
  final CustomerDisputesRepository? repository;
  final CustomerRepository? actions;
  final bool refreshOnOpen;
  @override
  State<CustomerDisputesScreen> createState() => _CustomerDisputesScreenState();
}

class _CustomerDisputesScreenState extends State<CustomerDisputesScreen>
    with WidgetsBindingObserver {
  late final _owner = AppDatabase.instance.accountId;
  late final _repository = widget.repository ?? CustomerDisputesRepository();
  late final _actions = widget.actions ?? CustomerRepository();
  final _reply = TextEditingController();
  List<Map<String, dynamic>> _rows = [], _queue = [];
  bool _loading = true, _syncing = false, _sending = false;
  String? _error, _selected;
  bool _entrySelectionResolved = false;
  int _version = 0;
  bool get _current =>
      mounted && _owner != null && AppDatabase.instance.accountId == _owner;
  @override
  void initState() {
    super.initState();
    _selected = widget.disputeId;
    WidgetsBinding.instance.addObserver(this);
    CustomerDisputesRepository.changes.addListener(_reload);
    CustomerOutbox.changes.addListener(_reload);
    unawaited(_load());
    if (widget.refreshOnOpen) unawaited(_sync());
  }

  void _reload() => unawaited(_load());
  Future<void> _load() async {
    if (!_current) return;
    final version = ++_version;
    try {
      final rows = await _repository.local(_owner!);
      final queue = await _actions.pendingActions();
      if (!_current || version != _version) return;
      setState(() {
        _rows = rows;
        _queue = queue
            .where(
              (a) => {'dispute', 'dispute_reply'}.contains(_payload(a)['kind']),
            )
            .toList();
        if (!_entrySelectionResolved &&
            _selected == null &&
            widget.entryId != null) {
          _selected =
              rows
                      .where((r) => r['entry_id'] == widget.entryId)
                      .firstOrNull?['id']
                  as String?;
          _entrySelectionResolved = _selected != null;
        }
        _loading = false;
        if (_error == 'تعذر قراءة الاعتراضات المحفوظة. أعد المحاولة.') {
          _error = null;
        }
      });
    } catch (_) {
      if (_current) {
        setState(() {
          _loading = false;
          _error = 'تعذر قراءة الاعتراضات المحفوظة. أعد المحاولة.';
        });
      }
    }
  }

  Map<String, dynamic> _payload(Map<String, dynamic> action) =>
      Map<String, dynamic>.from(jsonDecode(action['payload'] as String));
  Future<void> _sync() async {
    if (!_current || _syncing) return;
    setState(() {
      _syncing = true;
      _error = null;
    });
    try {
      await _actions.flushOutbox();
      if (!_current) return;
      await _repository.sync(_owner!);
    } catch (_) {
      if (_current) {
        setState(
          () => _error = 'تعذر تحديث الرد الآن. طلباتك محفوظة؛ حاول لاحقًا.',
        );
      }
    } finally {
      if (_current) {
        setState(() => _syncing = false);
        await _load();
      }
    }
  }

  Future<void> _send(String id) async {
    if (!_current || _sending || _reply.text.trim().isEmpty) return;
    setState(() => _sending = true);
    try {
      await _actions.replyToDispute(id, _reply.text);
      if (!_current) return;
      _reply.clear();
      PushNotificationService.instance.changes.value++;
      await _load();
      if (_current) unawaited(_sync());
    } catch (e) {
      if (mounted && _current) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_actions.friendlyError(e))));
      }
    } finally {
      if (_current) setState(() => _sending = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_sync());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    CustomerDisputesRepository.changes.removeListener(_reload);
    CustomerOutbox.changes.removeListener(_reload);
    _reply.dispose();
    super.dispose();
  }

  String _date(Object? value) {
    final parsed = DateTime.tryParse(value?.toString() ?? '');
    return parsed == null
        ? ''
        : DateFormat('yyyy/MM/dd HH:mm').format(parsed.toLocal());
  }

  Color _statusColor(String? status) => switch (status) {
    'awaiting_customer' => AppColors.warningStrong,
    'accepted' || 'partially_accepted' => AppColors.primary,
    'rejected' => AppColors.error,
    _ => AppColors.textSecondary,
  };

  void _showList() {
    _reply.clear();
    setState(() {
      _selected = null;
      _entrySelectionResolved = true;
    });
  }

  Widget _panel({required Widget child, Color? color}) => Container(
    margin: const EdgeInsets.only(bottom: 10),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: color ?? AppColors.white,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: AppColors.borderLight),
    ),
    child: child,
  );

  Widget _status(String? status) {
    final color = _statusColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .09),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        simpleCustomerDisputeStatus(status),
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _section(String title, IconData icon) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      children: [
        Icon(icon, size: 16, color: AppColors.primary),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
        ),
      ],
    ),
  );

  Widget _messageBubble(Map<String, dynamic> message) {
    final workspace = message['sender_workspace'] as String?;
    final fromCustomer =
        workspace == 'customer' ||
        (workspace == null && message['sender_user_id'] == _owner);
    return Align(
      alignment: fromCustomer
          ? AlignmentDirectional.centerEnd
          : AlignmentDirectional.centerStart,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * .78,
        ),
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
        decoration: BoxDecoration(
          color: fromCustomer ? AppColors.primaryContainer : AppColors.primary,
          borderRadius: BorderRadiusDirectional.only(
            topStart: const Radius.circular(15),
            topEnd: const Radius.circular(15),
            bottomStart: Radius.circular(fromCustomer ? 15 : 4),
            bottomEnd: Radius.circular(fromCustomer ? 4 : 15),
          ),
          border: Border.all(color: AppColors.borderLight),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              fromCustomer ? 'أنت • الزبون' : 'التاجر',
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                color: AppColors.primaryDark,
                fontSize: 11,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              message['message']?.toString() ?? '',
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                color: fromCustomer ? AppColors.textPrimary : AppColors.white,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              _date(message['created_at']),
              style: TextStyle(
                fontSize: 10,
                color: fromCustomer
                    ? AppColors.textSecondary
                    : AppColors.white70,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pending(Map<String, dynamic> action) {
    final payload = _payload(action);
    final failed = action['status'] == 'failed';
    return _panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                failed
                    ? Icons.error_outline_rounded
                    : Icons.check_circle_outline_rounded,
                color: failed ? AppColors.error : AppColors.primary,
                size: 21,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  payload['kind'] == 'dispute_reply' ? 'رسالتك' : 'طلبك محفوظ',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            payload['message']?.toString() ??
                payload['description']?.toString() ??
                '',
          ),
          const SizedBox(height: 8),
          Text(
            failed
                ? 'لم نتمكن من الإرسال. اضغط «إرسال مرة أخرى».'
                : 'طلبك محفوظ. سنرسله عند توفر الإنترنت.',
            style: TextStyle(
              fontSize: 12,
              height: 1.6,
              color: failed ? AppColors.error : AppColors.textSecondary,
            ),
          ),
          if (failed) ...[
            const SizedBox(height: 6),
            Text(
              action['error']?.toString() ?? 'تعذر إرسال الطلب',
              style: const TextStyle(color: AppColors.error),
            ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: _syncing
                    ? null
                    : () async {
                        await _actions.retryAction(action['id'] as String);
                        if (_current) unawaited(_sync());
                      },
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('إرسال مرة أخرى'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _detail(Map<String, dynamic> dispute) {
    final entry = Map<String, dynamic>.from(dispute['entry'] as Map? ?? {});
    final currency = entry['currency_code'] ?? '';
    final pending = _queue
        .where((a) => _payload(a)['target_id'] == dispute['id'])
        .toList();
    final status = dispute['status'] as String?;
    final open = customerDisputeOpen(status);
    final messages = List<Map<String, dynamic>>.from(
      dispute['messages'] as List? ?? [],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry['description']?.toString() ?? 'عملية مسجلة',
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          _date(entry['occurred_at']),
                          style: AppTypography.caption(
                            color: AppColors.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      '${entry['amount'] ?? '—'} $currency',
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: AppColors.primaryDark,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _status(status),
              const Divider(height: 20),
              const Text(
                'طلبك',
                style: TextStyle(fontSize: 11, color: AppColors.textMuted),
              ),
              const SizedBox(height: 3),
              Text(
                dispute['description']?.toString() ?? '',
                style: const TextStyle(fontSize: 13, height: 1.5),
              ),
              const SizedBox(height: 4),
              Text(
                'تاريخ التقديم: ${_date(dispute['created_at'])}',
                style: AppTypography.caption(color: AppColors.textSecondary),
              ),
              if (!open || dispute['resolution_note'] != null) ...[
                const Divider(height: 20),
                _section('رد التاجر', Icons.fact_check_outlined),
                if (dispute['resolution_note'] != null)
                  Text(
                    '${dispute['resolution_note']}',
                    style: const TextStyle(height: 1.7),
                  ),
                if (dispute['status'] == 'accepted') ...[
                  const SizedBox(height: 8),
                  const Text(
                    'وافق التاجر وألغى أثر هذه العملية. سيظهر التحديث في كشف حسابك.',
                  ),
                ],
                if (dispute['status'] == 'partially_accepted') ...[
                  if (dispute['corrected_amount'] != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      'المبلغ قبل التصحيح: ${entry['amount']} $currency\nالمبلغ بعد التصحيح: ${dispute['corrected_amount']} $currency',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        height: 1.9,
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  const Text(
                    'صحح التاجر المبلغ. سيظهر المبلغ الجديد في كشف حسابك.',
                  ),
                ],
                if (status == 'rejected') ...[
                  const SizedBox(height: 8),
                  const Text(
                    'لم يتغير مبلغ العملية. يمكنك مراجعة سبب القرار أعلاه.',
                  ),
                ],
                if (dispute['resolved_at'] != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    'تاريخ القرار: ${_date(dispute['resolved_at'])}',
                    style: AppTypography.caption(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
        _section('الحديث مع التاجر', Icons.forum_outlined),
        if (messages.isEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 20),
            child: Text(
              'لم يرسل التاجر رسائل إضافية.',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ),
        for (final message in messages) _messageBubble(message),
        ...pending.map(_pending),
      ],
    );
  }

  Widget _composer(Map<String, dynamic> dispute) {
    final pending = _queue.any(
      (a) => _payload(a)['target_id'] == dispute['id'],
    );
    final enabled = !_sending && !pending;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.white,
          border: Border(top: BorderSide(color: AppColors.borderLight)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: _reply,
                    minLines: 1,
                    maxLines: 3,
                    maxLength: 4000,
                    enabled: enabled,
                    style: const TextStyle(fontSize: 13, height: 1.5),
                    decoration: InputDecoration(
                      hintText: 'اكتب ردك للتاجر…',
                      counterText: '',
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      filled: true,
                      fillColor: AppColors.backgroundLight,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(
                          color: AppColors.borderLight,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  tooltip: 'إرسال الرسالة',
                  onPressed: enabled
                      ? () => _send(dispute['id'] as String)
                      : null,
                  icon: const Icon(Icons.send_rounded, size: 20),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _iconTile(IconData icon) => Container(
    padding: const EdgeInsets.all(7),
    decoration: BoxDecoration(
      color: AppColors.primaryContainer,
      borderRadius: BorderRadius.circular(9),
    ),
    child: Icon(icon, color: AppColors.primaryDark, size: 18),
  );

  Widget _listItem(Map<String, dynamic> dispute) {
    final entry = Map<String, dynamic>.from(dispute['entry'] as Map? ?? {});
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: AppColors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: AppColors.borderLight),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => setState(() {
            _reply.clear();
            _selected = dispute['id'] as String;
          }),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    _iconTile(Icons.storefront_outlined),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            dispute['business_name']?.toString() ?? 'المتجر',
                            style: AppTypography.titleSmall(
                              color: AppColors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _date(dispute['created_at']),
                            style: AppTypography.caption(
                              color: AppColors.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Icon(
                      Icons.chevron_left_rounded,
                      color: AppColors.textMuted,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        dispute['description']?.toString() ?? '',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13, height: 1.5),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        '${entry['amount'] ?? '—'} ${entry['currency_code'] ?? ''}',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: AppColors.primaryDark,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _status(dispute['status'] as String?),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_current) {
      return const Scaffold(
        body: Center(child: Text('افتح طلباتك من حسابك الحالي.')),
      );
    }
    final selected = _rows.where((r) => r['id'] == _selected).firstOrNull;
    return PopScope(
      canPop: _selected == null,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && mounted) {
          _showList();
        }
      },
      child: Scaffold(
        backgroundColor: AppColors.backgroundLight,
        appBar: AppBar(
          backgroundColor: AppColors.primaryDark,
          foregroundColor: AppColors.white,
          elevation: 0,
          scrolledUnderElevation: 0,
          toolbarHeight:
              64 + (MediaQuery.textScalerOf(context).scale(16) - 16) * 2,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(bottom: Radius.circular(12)),
          ),
          titleSpacing: 4,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                selected != null ? 'متابعة طلبك' : 'طلباتي للتاجر',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppColors.white,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                selected != null
                    ? selected['business_name']?.toString() ?? 'المتجر'
                    : 'طلباتك وردود التجار في مكان واحد',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.textWhiteSecondary,
                  height: 1.5,
                ),
              ),
            ],
          ),
          leading: _selected == null
              ? null
              : BackButton(
                  onPressed: () {
                    _showList();
                  },
                ),
          actions: [
            IconButton(
              onPressed: _syncing ? null : () => unawaited(_sync()),
              style: IconButton.styleFrom(
                backgroundColor: AppColors.white.withValues(alpha: .12),
                foregroundColor: AppColors.white,
                disabledForegroundColor: AppColors.white60,
              ),
              icon: const Icon(Icons.refresh_rounded, size: 21),
              tooltip: 'تحديث الطلبات',
            ),
            const SizedBox(width: 12),
          ],
        ),
        bottomNavigationBar:
            selected != null &&
                customerDisputeOpen(selected['status'] as String?)
            ? _composer(selected)
            : null,
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: () async {
                  unawaited(_sync());
                  await _load();
                },
                child: ListView(
                  key: ValueKey(_selected ?? 'dispute-list'),
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
                  children: [
                    if (_error != null)
                      _panel(
                        child: Text(
                          _error!,
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ),
                    if (selected != null)
                      _detail(selected)
                    else ...[
                      if (_selected != null)
                        _panel(
                          child: const Text(
                            'لم تُحمّل تفاصيل هذا الاعتراض بعد، أو تغير الوصول إليه. حدّث الصفحة عند الاتصال.',
                          ),
                        ),
                      ..._queue
                          .where((a) => _payload(a)['kind'] == 'dispute')
                          .map(_pending),
                      if (_rows.isEmpty && _queue.isEmpty)
                        _panel(
                          child: Column(
                            children: [
                              const SizedBox(height: 16),
                              const Icon(
                                Icons.fact_check_outlined,
                                color: AppColors.primary,
                                size: 44,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                'لا توجد طلبات بعد',
                                style: AppTypography.titleSmall(
                                  color: AppColors.textPrimary,
                                ),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 8),
                              const Text(
                                'إذا وجدت خطأ، افتح العملية واضغط «لدي مشكلة». سنعرض رد التاجر هنا.',
                                style: TextStyle(
                                  color: AppColors.textSecondary,
                                  height: 1.7,
                                ),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 16),
                            ],
                          ),
                        ),
                      ..._rows.map(_listItem),
                      ..._queue
                          .where((a) => _payload(a)['kind'] == 'dispute_reply')
                          .map(_pending),
                    ],
                  ],
                ),
              ),
      ),
    );
  }
}
