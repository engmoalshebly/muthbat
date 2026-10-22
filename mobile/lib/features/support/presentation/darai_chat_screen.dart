import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_typography.dart';
import '../data/darai_chat_client.dart';

class DaraiChatScreen extends StatefulWidget {
  const DaraiChatScreen({
    super.key,
    this.config = DaraiChatClient.developmentConfig,
    this.title = 'دردشة الدعم',
    this.welcomeTitle = 'أهلًا بك في داري',
    this.welcomeMessage = 'اكتب رسالتك وسنساعدك بكل سرور.',
    this.allowImageAttachments = true,
  });

  final DaraiChatConfig config;
  final String title;
  final String welcomeTitle;
  final String welcomeMessage;
  final bool allowImageAttachments;

  @override
  State<DaraiChatScreen> createState() => _DaraiChatScreenState();
}

class _DaraiChatScreenState extends State<DaraiChatScreen> {
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  final _imagePicker = ImagePicker();
  final List<_ChatMessage> _messages = [];
  final Set<String> _receivedMessageIds = {};
  late final DaraiChatClient _client;
  String _connectionState = 'جارٍ الاتصال';
  String? _connectionError;
  bool _connected = false;
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    _client = DaraiChatClient(onEvent: _handleEvent, config: widget.config);
    unawaited(_client.connect());
  }

  void _handleEvent(Map<String, dynamic> event) {
    if (!mounted) return;
    final name = event['event'];
    String? receivedMessageId;
    setState(() {
      switch (name) {
        case 'connection.ready':
          _connected = true;
          _connectionState = 'متصل';
          _connectionError = null;
        case 'connection.error':
          _connected = false;
          _connectionState = 'الاتصال غير متاح';
          _connectionError = event['message']?.toString();
        case 'message.ack':
          final id = event['id'];
          if (id is String) _updateMessage(id, 'تم الإرسال');
        case 'system.error':
          final id = event['id'];
          final retryable = event['retryable'] == true;
          if (id is String) {
            _updateMessage(
              id,
              retryable ? 'تعذر الإرسال - أعد المحاولة' : 'رفض الخادم الرسالة',
              canRetry: retryable,
            );
          }
        case 'message.new':
          final payload = event['payload'];
          if (payload is Map<String, dynamic>) {
            final id = payload['message_id'];
            final text = payload['text'];
            if (id is String && !_receivedMessageIds.add(id)) break;
            _messages.add(
              _ChatMessage(
                id: id is String ? id : null,
                text: text is String && text.isNotEmpty
                    ? text
                    : 'وصل رد جديد من الدعم',
                incoming: true,
                createdAt: DateTime.now(),
              ),
            );
            if (id is String && _connected) receivedMessageId = id;
          }
      }
    });
    _scrollToBottom(markReadId: receivedMessageId);
  }

  void _updateMessage(String id, String status, {bool canRetry = false}) {
    final index = _messages.indexWhere((message) => message.id == id);
    if (index != -1) {
      _messages[index] = _messages[index].copyWith(
        status: status,
        canRetry: canRetry,
      );
    }
  }

  void _sendMessage() {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;
    try {
      final id = _client.sendText(text);
      setState(() {
        _messages.add(
          _ChatMessage(
            id: id,
            text: text,
            incoming: false,
            status: 'بانتظار الإقرار',
            createdAt: DateTime.now(),
          ),
        );
        _inputController.clear();
      });
      _scrollToBottom();
    } on Object catch (error) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('تعذر إرسال الرسالة: $error')));
    }
  }

  Future<void> _sendImage() async {
    try {
      final image = await _imagePicker.pickImage(source: ImageSource.gallery);
      if (image == null || !mounted) return;
      final mimeType =
          image.mimeType?.toLowerCase() ?? _imageMimeType(image.name);
      if (mimeType == null) {
        throw const FormatException(
          'صيغة الصورة غير مدعومة. اختر JPEG أو PNG أو WebP.',
        );
      }
      setState(() => _uploading = true);
      final uploadToken = await _client.uploadFile(
        file: File(image.path),
        type: 'image',
        mimeType: mimeType,
        filename: image.name,
      );
      final id = _client.sendUpload(type: 'image', uploadToken: uploadToken);
      if (!mounted) return;
      setState(() {
        _messages.add(
          _ChatMessage(
            id: id,
            text: 'صورة مرفقة',
            incoming: false,
            status: 'بانتظار الإقرار',
            createdAt: DateTime.now(),
          ),
        );
      });
      _scrollToBottom();
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('تعذر رفع الصورة: $error')));
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  String? _imageMimeType(String filename) {
    final extension = filename.split('.').last.toLowerCase();
    return switch (extension) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'webp' => 'image/webp',
      _ => null,
    };
  }

  void _reconnect() {
    setState(() {
      _connected = false;
      _connectionError = null;
      _connectionState = 'جارٍ إعادة الاتصال';
    });
    unawaited(_client.reconnect());
  }

  void _scrollToBottom({String? markReadId}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController
          .animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
          )
          .then((_) {
            if (mounted && markReadId != null) _client.markRead(markReadId);
          });
    });
  }

  @override
  void dispose() {
    unawaited(_client.dispose());
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundLight,
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        foregroundColor: AppColors.white,
        titleSpacing: 0,
        title: Row(
          children: [
            const CircleAvatar(
              radius: 19,
              backgroundColor: AppColors.primaryLight,
              child: Icon(
                Icons.support_agent_rounded,
                color: AppColors.white,
                size: 23,
              ),
            ),
            const SizedBox(width: 11),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.title,
                  style: AppTypography.titleMedium(color: AppColors.white),
                ),
                Text(
                  'فريق داري',
                  style: AppTypography.bodySmall(
                    color: AppColors.textWhiteSecondary,
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'إعادة الاتصال',
            onPressed: _connected ? null : _reconnect,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: Column(
        children: [
          _ConnectionBanner(
            connected: _connected,
            title: _connectionState,
            error: _connectionError,
            onRetry: _connected ? null : _reconnect,
          ),
          Expanded(
            child: _messages.isEmpty
                ? _WelcomePanel(
                    title: widget.welcomeTitle,
                    message: widget.welcomeMessage,
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final message = _messages[index];
                      return _MessageBubble(
                        message: message,
                        onRetry: message.id == null
                            ? null
                            : () => _client.retry(message.id!),
                      );
                    },
                  ),
          ),
          SafeArea(
            top: false,
            child: _ChatComposer(
              controller: _inputController,
              uploading: _uploading,
              allowAttachments: widget.allowImageAttachments,
              onSend: _sendMessage,
              onAttach: _sendImage,
            ),
          ),
        ],
      ),
    );
  }
}

class _ChatMessage {
  const _ChatMessage({
    required this.id,
    required this.text,
    required this.incoming,
    required this.createdAt,
    this.status,
    this.canRetry = false,
  });

  final String? id;
  final String text;
  final bool incoming;
  final DateTime createdAt;
  final String? status;
  final bool canRetry;

  _ChatMessage copyWith({String? status, bool? canRetry}) => _ChatMessage(
    id: id,
    text: text,
    incoming: incoming,
    createdAt: createdAt,
    status: status ?? this.status,
    canRetry: canRetry ?? this.canRetry,
  );
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message, this.onRetry});

  final _ChatMessage message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final incoming = message.incoming;
    final color = incoming ? AppColors.white : AppColors.primaryContainer;
    return Align(
      alignment: incoming ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * .82,
        ),
        child: Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.fromLTRB(15, 11, 15, 8),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(20),
              topRight: const Radius.circular(20),
              bottomLeft: Radius.circular(incoming ? 5 : 20),
              bottomRight: Radius.circular(incoming ? 20 : 5),
            ),
            border: Border.all(
              color: incoming ? AppColors.borderSubtle : AppColors.transparent,
            ),
            boxShadow: [
              BoxShadow(
                color: AppColors.primary.withValues(alpha: .04),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                message.text,
                textDirection: TextDirection.rtl,
                style: AppTypography.bodyLarge(),
              ),
              const SizedBox(height: 5),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!incoming && message.status != null) ...[
                    if (message.canRetry)
                      InkWell(
                        onTap: onRetry,
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 2,
                          ),
                          child: Text(
                            'إعادة الإرسال',
                            style: AppTypography.bodySmall(
                              color: AppColors.error,
                            ),
                          ),
                        ),
                      )
                    else
                      Icon(
                        message.status == 'تم الإرسال'
                            ? Icons.done_all_rounded
                            : Icons.schedule_rounded,
                        size: 14,
                        color: message.status == 'تم الإرسال'
                            ? AppColors.secondary
                            : AppColors.textMuted,
                      ),
                    const SizedBox(width: 4),
                    Text(message.status!, style: AppTypography.bodySmall()),
                  ],
                  if (incoming || message.status == null) ...[
                    Text(
                      TimeOfDay.fromDateTime(message.createdAt).format(context),
                      style: AppTypography.bodySmall(),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConnectionBanner extends StatelessWidget {
  const _ConnectionBanner({
    required this.connected,
    required this.title,
    required this.error,
    required this.onRetry,
  });

  final bool connected;
  final String title;
  final String? error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final color = connected ? AppColors.success : AppColors.warning;
    return Container(
      width: double.infinity,
      color: connected ? AppColors.successLight : AppColors.warningLight,
      padding: const EdgeInsetsDirectional.fromSTEB(16, 9, 12, 9),
      child: Row(
        children: [
          Icon(
            connected ? Icons.check_circle_rounded : Icons.info_outline_rounded,
            size: 17,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppTypography.bodySmall(color: color)),
                if (!connected && error != null)
                  Text(
                    'سيحاول التطبيق إعادة الاتصال تلقائيًا.',
                    style: AppTypography.bodySmall(
                      color: AppColors.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
          if (!connected && onRetry != null)
            TextButton(
              onPressed: onRetry,
              child: Text(
                'إعادة المحاولة',
                style: AppTypography.bodySmall(color: color),
              ),
            ),
        ],
      ),
    );
  }
}

class _WelcomePanel extends StatelessWidget {
  const _WelcomePanel({required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 82,
              height: 82,
              decoration: const BoxDecoration(
                color: AppColors.primaryContainer,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.forum_rounded,
                size: 38,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              title,
              textAlign: TextAlign.center,
              style: AppTypography.titleLarge(color: AppColors.primary),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: AppTypography.bodyMedium(),
            ),
            const SizedBox(height: 18),
            const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.lock_outline_rounded,
                  size: 14,
                  color: AppColors.textMuted,
                ),
                SizedBox(width: 5),
                Text(
                  'اتصال آمن ومشفّر',
                  style: TextStyle(
                    fontFamily: AppTypography.fontFamily,
                    fontSize: 11,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatComposer extends StatelessWidget {
  const _ChatComposer({
    required this.controller,
    required this.uploading,
    required this.allowAttachments,
    required this.onSend,
    required this.onAttach,
  });

  final TextEditingController controller;
  final bool uploading;
  final bool allowAttachments;
  final VoidCallback onSend;
  final VoidCallback onAttach;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.white,
        border: Border(top: BorderSide(color: AppColors.borderSubtle)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (allowAttachments)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: IconButton(
                tooltip: 'إرفاق صورة',
                onPressed: uploading ? null : onAttach,
                style: IconButton.styleFrom(
                  foregroundColor: AppColors.textSecondary,
                ),
                icon: uploading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.attach_file_rounded),
              ),
            ),
          Expanded(
            child: TextField(
              controller: controller,
              textDirection: TextDirection.rtl,
              textInputAction: TextInputAction.newline,
              keyboardType: TextInputType.multiline,
              minLines: 1,
              maxLines: 5,
              onSubmitted: (_) => onSend(),
              decoration: InputDecoration(
                hintText: 'اكتب رسالتك هنا...',
                hintStyle: AppTypography.bodyMedium(color: AppColors.textMuted),
                filled: true,
                fillColor: AppColors.backgroundLight,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(22),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 12,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller,
              builder: (context, value, _) => IconButton.filled(
                onPressed: value.text.trim().isEmpty ? null : onSend,
                tooltip: 'إرسال',
                style: IconButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  disabledBackgroundColor: AppColors.primaryContainer,
                  foregroundColor: AppColors.white,
                  disabledForegroundColor: AppColors.textMuted,
                ),
                icon: const Icon(Icons.send_rounded),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
