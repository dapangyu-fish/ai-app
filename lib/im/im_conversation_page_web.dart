import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import 'package:web/web.dart' as web;

import '../auth/auth_service.dart';
import '../config/app_config.dart';
import 'im_service.dart';

class IMConversationPage extends StatefulWidget {
  const IMConversationPage({super.key});

  @override
  State<IMConversationPage> createState() => _IMConversationPageState();
}

class _IMConversationPageState extends State<IMConversationPage> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _conversations = const [];
  StreamSubscription<void>? _convSub;
  StreamSubscription<Map<String, dynamic>>? _msgSub;

  @override
  void initState() {
    super.initState();
    _convSub = IMService.instance.conversationsChangedStream.listen((_) {
      _load();
    });
    _msgSub = IMService.instance.newMessageMapStream.listen((_) {
      _load();
    });
    _load();
  }

  @override
  void dispose() {
    _convSub?.cancel();
    _msgSub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final ok = await IMService.instance.login();
      if (!ok) throw Exception('OpenIM 登录失败');
      final list = await IMService.instance.getConversationListAsMaps();
      final merged = await _mergeConversationProfiles(list);
      if (!mounted) return;
      setState(() {
        _conversations = merged;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  Future<List<Map<String, dynamic>>> _mergeConversationProfiles(
    List<Map<String, dynamic>> list,
  ) async {
    final ids = list
        .map((c) => c['user_id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList();
    if (ids.isEmpty) return list;
    final profiles = await IMService.instance.lookupUsersFromSupabase(ids);
    return list.map((c) {
      final userID = c['user_id']?.toString() ?? '';
      final p = profiles[userID];
      if (p == null) return c;
      return {
        ...c,
        if ((c['show_name']?.toString() ?? '').isEmpty)
          'show_name':
              p['nickname']?.toString() ??
              p['display_name']?.toString() ??
              p['username']?.toString() ??
              p['email']?.toString() ??
              userID,
        if ((c['face_url']?.toString() ?? '').isEmpty)
          'face_url':
              p['face_url']?.toString() ?? p['avatar_url']?.toString() ?? '',
      };
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('消息'),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: '联系人',
            onPressed: () {
              Navigator.of(context)
                  .push(
                    MaterialPageRoute(builder: (_) => const _WebFriendPage()),
                  )
                  .then((_) => _load());
            },
            icon: const Icon(Icons.people_outline),
          ),
          IconButton(
            tooltip: '刷新',
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error!, textAlign: TextAlign.center),
              ),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: _conversations.isEmpty
                  ? ListView(
                      children: const [
                        SizedBox(height: 160),
                        Center(child: Text('暂无会话')),
                      ],
                    )
                  : ListView.separated(
                      itemCount: _conversations.length,
                      separatorBuilder: (_, __) =>
                          Divider(height: 1, color: cs.outlineVariant),
                      itemBuilder: (context, index) {
                        final c = _conversations[index];
                        final unread = c['display_unread']?.toString() ?? '';
                        return ListTile(
                          leading: _Avatar(url: c['face_url']?.toString()),
                          title: Text(
                            c['show_name']?.toString().isNotEmpty == true
                                ? c['show_name'].toString()
                                : c['user_id']?.toString() ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            c['latest_text']?.toString() ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                c['display_time']?.toString() ?? '',
                                style: TextStyle(
                                  color: cs.onSurfaceVariant,
                                  fontSize: 12,
                                ),
                              ),
                              if (unread.isNotEmpty) ...[
                                const SizedBox(height: 6),
                                Badge(label: Text(unread)),
                              ],
                            ],
                          ),
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => _WebChatPage(conversation: c),
                              ),
                            );
                          },
                        );
                      },
                    ),
            ),
    );
  }
}

class _WebChatPage extends StatefulWidget {
  final Map<String, dynamic> conversation;

  const _WebChatPage({required this.conversation});

  @override
  State<_WebChatPage> createState() => _WebChatPageState();
}

class _WebChatPageState extends State<_WebChatPage> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final Map<String, String> _avatarCache = {};
  bool _loading = true;
  bool _sending = false;
  String? _error;
  List<Map<String, dynamic>> _messages = const [];
  StreamSubscription<Map<String, dynamic>>? _msgSub;

  String get _conversationID =>
      widget.conversation['conversation_id']?.toString() ?? '';

  String get _peerUserID => widget.conversation['user_id']?.toString() ?? '';
  String get _groupID => widget.conversation['group_id']?.toString() ?? '';
  int get _conversationType => widget.conversation['conversation_type'] is int
      ? widget.conversation['conversation_type'] as int
      : int.tryParse(
              widget.conversation['conversation_type']?.toString() ?? '',
            ) ??
            1;

  @override
  void initState() {
    super.initState();
    _msgSub = IMService.instance.newMessageMapStream.listen((message) {
      final recv = message['recv_id']?.toString() ?? '';
      final send = message['send_id']?.toString() ?? '';
      final userID = widget.conversation['user_id']?.toString() ?? '';
      if (userID.isEmpty || recv == userID || send == userID) {
        setState(() => _messages = [..._messages, message]);
        _jumpToBottom();
      }
    });
    _load();
  }

  @override
  void dispose() {
    _msgSub?.cancel();
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await IMService.instance.getHistoryMessagesAsMaps(
        conversationID: _conversationID,
        count: 50,
      );
      await IMService.instance.markConversationRead(
        conversationID: _conversationID,
      );
      if (!mounted) return;
      setState(() {
        _messages = list;
        _loading = false;
      });
      await _ensureAvatars(_messages);
      _jumpToBottom();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  Future<void> _ensureAvatars(List<Map<String, dynamic>> messages) async {
    final ids = <String>{
      widget.conversation['user_id']?.toString() ?? '',
      for (final m in messages) m['send_id']?.toString() ?? '',
    }..removeWhere((id) => id.isEmpty || _avatarCache.containsKey(id));
    if (ids.isEmpty) return;
    final profiles = await IMService.instance.lookupUsersFromSupabase(
      ids.toList(),
    );
    if (!mounted) return;
    setState(() {
      for (final id in ids) {
        final p = profiles[id];
        _avatarCache[id] =
            p?['face_url']?.toString() ?? p?['avatar_url']?.toString() ?? '';
      }
    });
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    _controller.clear();
    try {
      final sent = await IMService.instance.sendTextMessageAsMap(
        conversationID: _conversationID,
        text: text,
        userID: _peerUserID,
        groupID: _groupID,
        conversationType: _conversationType,
      );
      if (!mounted) return;
      if (sent != null) {
        setState(() => _messages = [..._messages, sent]);
        _jumpToBottom();
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _pickAndSendImage() async {
    if (_sending) return;
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null || !mounted) return;
    setState(() => _sending = true);
    final placeholder = _localMessage('[图片上传中...]', contentType: 101);
    setState(() => _messages = [..._messages, placeholder]);
    _jumpToBottom();
    try {
      final bytes = await picked.readAsBytes();
      final dim = await _readImageDim(bytes);
      final upload = await _WebImMediaUploader.uploadBytes(
        bytes,
        fileName: picked.name,
        purpose: 'image',
        contentType: picked.mimeType,
      );
      if (upload == null) throw Exception('图片上传失败');
      final sent = await IMService.instance.sendImageByUrlAsMap(
        conversationID: _conversationID,
        url: upload.publicUrl,
        sourcePath: picked.name.isNotEmpty ? picked.name : upload.key,
        uuid: upload.key,
        width: dim?.$1 ?? 0,
        height: dim?.$2 ?? 0,
        size: bytes.length,
        userID: _peerUserID,
        groupID: _groupID,
        conversationType: _conversationType,
      );
      _replacePlaceholder(placeholder, sent, '[图片发送失败]');
    } catch (e) {
      _replacePlaceholder(placeholder, null, '[图片发送失败]');
      _toast(e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _pickAndSendVideo() async {
    if (_sending) return;
    final picked = await ImagePicker().pickVideo(
      source: ImageSource.gallery,
      maxDuration: const Duration(minutes: 3),
    );
    if (picked == null || !mounted) return;
    setState(() => _sending = true);
    final placeholder = _localMessage('[视频上传中...]', contentType: 101);
    setState(() => _messages = [..._messages, placeholder]);
    _jumpToBottom();
    try {
      final bytes = await picked.readAsBytes();
      final upload = await _WebImMediaUploader.uploadBytes(
        bytes,
        fileName: picked.name,
        purpose: 'video',
        contentType: picked.mimeType ?? 'video/mp4',
      );
      if (upload == null) throw Exception('视频上传失败');
      final sent = await IMService.instance.sendVideoByUrlAsMap(
        conversationID: _conversationID,
        videoUrl: upload.publicUrl,
        videoSourcePath: picked.name.isNotEmpty ? picked.name : upload.key,
        videoUuid: upload.key,
        videoType: picked.mimeType ?? 'video/mp4',
        videoSize: bytes.length,
        duration: 0,
        userID: _peerUserID,
        groupID: _groupID,
        conversationType: _conversationType,
      );
      _replacePlaceholder(placeholder, sent, '[视频发送失败]');
    } catch (e) {
      _replacePlaceholder(placeholder, null, '[视频发送失败]');
      _toast(e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _showAttachmentOptions() {
    final cs = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _AttachmentAction(
                icon: Icons.photo,
                label: '图片',
                color: cs.primary,
                onTap: () {
                  Navigator.pop(ctx);
                  _pickAndSendImage();
                },
              ),
              _AttachmentAction(
                icon: Icons.videocam,
                label: '视频',
                color: cs.primary,
                onTap: () {
                  Navigator.pop(ctx);
                  _pickAndSendVideo();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Map<String, dynamic> _localMessage(String text, {required int contentType}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return {
      'client_msg_id': 'web_local_$now',
      'send_id': IMService.instance.currentUserId ?? '',
      'recv_id': _peerUserID,
      'send_time': now,
      'content_type': contentType,
      'text': text,
      'is_me': true,
      'is_other': false,
      'display_time': '',
    };
  }

  void _replacePlaceholder(
    Map<String, dynamic> placeholder,
    Map<String, dynamic>? sent,
    String failedText,
  ) {
    if (!mounted) return;
    setState(() {
      final id = placeholder['client_msg_id'];
      final idx = _messages.indexWhere((m) => m['client_msg_id'] == id);
      if (idx < 0) return;
      final next = [..._messages];
      next[idx] = sent ?? {...placeholder, 'text': failedText};
      _messages = next;
    });
    _jumpToBottom();
  }

  Future<(int, int)?> _readImageDim(Uint8List bytes) async {
    try {
      final completer = Completer<(int, int)?>();
      ui.decodeImageFromList(bytes, (image) {
        completer.complete((image.width, image.height));
      });
      return completer.future.timeout(const Duration(seconds: 5));
    } catch (_) {
      return null;
    }
  }

  void _toast(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
    );
  }

  void _jumpToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final title =
        widget.conversation['show_name']?.toString().isNotEmpty == true
        ? widget.conversation['show_name'].toString()
        : widget.conversation['user_id']?.toString() ?? '聊天';
    return Scaffold(
      appBar: AppBar(title: Text(title), centerTitle: true),
      body: Column(
        children: [
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(_error!, textAlign: TextAlign.center),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(12),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final m = _messages[index];
                      final isMe = m['is_me'] == true;
                      return _MessageBubble(
                        message: m,
                        avatarUrl: _avatarFor(m),
                        isMe: isMe,
                      );
                    },
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(
                children: [
                  IconButton(
                    tooltip: '添加',
                    onPressed: _sending ? null : _showAttachmentOptions,
                    icon: const Icon(Icons.add_circle_outline),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: const InputDecoration(
                        hintText: '输入消息',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _sending ? null : _send,
                    icon: _sending
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _avatarFor(Map<String, dynamic> message) {
    final embedded = message['sender_face_url']?.toString() ?? '';
    if (embedded.isNotEmpty) return embedded;
    final sendID = message['send_id']?.toString() ?? '';
    return _avatarCache[sendID] ?? '';
  }
}

class _MessageBubble extends StatelessWidget {
  final Map<String, dynamic> message;
  final String avatarUrl;
  final bool isMe;

  const _MessageBubble({
    required this.message,
    required this.avatarUrl,
    required this.isMe,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bubble = Container(
      constraints: const BoxConstraints(maxWidth: 420),
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: isMe ? const Color(0xFF95EC69) : cs.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: _MessageContent(message: message, isMe: isMe),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: isMe
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isMe) _Avatar(url: avatarUrl, radius: 18),
          if (!isMe) const SizedBox(width: 8),
          Flexible(child: bubble),
          if (isMe) const SizedBox(width: 8),
          if (isMe) _Avatar(url: avatarUrl, radius: 18),
        ],
      ),
    );
  }
}

class _AttachmentAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _AttachmentAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: color.withAlpha(25),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(icon, color: color, size: 28),
          ),
          const SizedBox(height: 8),
          Text(label, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }
}

class _MessageContent extends StatelessWidget {
  final Map<String, dynamic> message;
  final bool isMe;

  const _MessageContent({required this.message, required this.isMe});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final contentType = _toInt(message['content_type']);
    final textColor = isMe ? Colors.black : cs.onSurface;
    switch (contentType) {
      case 102:
        final url = _firstNonEmpty([
          message['image_url'],
          message['image_thumb_url'],
        ]);
        if (url.isEmpty) return Text('图片', style: TextStyle(color: textColor));
        return GestureDetector(
          onTap: () => _openImagePreview(context, url),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.network(
              url,
              width: 200,
              fit: BoxFit.cover,
              webHtmlElementStrategy: WebHtmlElementStrategy.prefer,
              errorBuilder: (_, __, ___) => _MediaPlaceholder(
                icon: Icons.broken_image_outlined,
                label: '图片已过期',
                color: textColor,
              ),
            ),
          ),
        );
      case 103:
        final duration = _toInt(message['sound_duration']);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.mic, size: 16, color: textColor),
            const SizedBox(width: 4),
            Text(
              duration > 0 ? '${duration}s' : '语音',
              style: TextStyle(color: textColor),
            ),
          ],
        );
      case 104:
        final videoUrl = message['video_url']?.toString() ?? '';
        final snapshot = message['video_snapshot_url']?.toString() ?? '';
        return GestureDetector(
          onTap: videoUrl.isNotEmpty
              ? () => _openVideoPreview(context, videoUrl)
              : null,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (snapshot.isNotEmpty)
                  Image.network(
                    snapshot,
                    width: 200,
                    fit: BoxFit.cover,
                    webHtmlElementStrategy: WebHtmlElementStrategy.prefer,
                    errorBuilder: (_, __, ___) => const _VideoBase(),
                  )
                else
                  const _VideoBase(),
                const Icon(
                  Icons.play_circle_filled,
                  size: 48,
                  color: Colors.white70,
                ),
                if (_toInt(message['video_duration']) > 0)
                  Positioned(
                    right: 6,
                    bottom: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        _fmtDuration(_toInt(message['video_duration'])),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      case 105:
        final name = message['file_name']?.toString().isNotEmpty == true
            ? message['file_name'].toString()
            : '文件';
        final url = message['file_url']?.toString() ?? '';
        return InkWell(
          onTap: url.isNotEmpty ? () => _openUrl(url) : null,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.insert_drive_file_outlined, color: textColor),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: textColor),
                ),
              ),
            ],
          ),
        );
      default:
        return SelectableText(
          message['text']?.toString() ?? '',
          style: TextStyle(color: textColor, fontSize: 15),
        );
    }
  }
}

void _openImagePreview(BuildContext context, String url) {
  Navigator.of(context).push(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _WebImagePreviewPage(url: url),
    ),
  );
}

void _openVideoPreview(BuildContext context, String url) {
  Navigator.of(context).push(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _WebVideoPreviewPage(url: url),
    ),
  );
}

void _downloadUrl(String url) {
  final segments = Uri.tryParse(url)?.pathSegments ?? const <String>[];
  final fileName = segments.isEmpty ? 'media' : segments.last;
  web.HTMLAnchorElement()
    ..href = url
    ..download = fileName.isEmpty ? 'media' : fileName
    ..target = '_blank'
    ..click();
}

class _WebImagePreviewPage extends StatelessWidget {
  final String url;

  const _WebImagePreviewPage({required this.url});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 5,
              child: Center(
                child: Image.network(
                  url,
                  fit: BoxFit.contain,
                  webHtmlElementStrategy: WebHtmlElementStrategy.prefer,
                  errorBuilder: (_, __, ___) => const Icon(
                    Icons.broken_image_outlined,
                    color: Colors.white70,
                    size: 48,
                  ),
                ),
              ),
            ),
          ),
          _PreviewCloseButton(onPressed: () => Navigator.pop(context)),
          _PreviewDownloadButton(onPressed: () => _downloadUrl(url)),
        ],
      ),
    );
  }
}

class _WebVideoPreviewPage extends StatefulWidget {
  final String url;

  const _WebVideoPreviewPage({required this.url});

  @override
  State<_WebVideoPreviewPage> createState() => _WebVideoPreviewPageState();
}

class _WebVideoPreviewPageState extends State<_WebVideoPreviewPage> {
  VideoPlayerController? _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _setup();
  }

  Future<void> _setup() async {
    try {
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(widget.url),
      );
      await controller.initialize();
      await controller.play();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _controller = controller);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    Widget body;
    if (_error != null) {
      body = Center(
        child: Text(_error!, style: const TextStyle(color: Colors.white70)),
      );
    } else if (controller == null) {
      body = const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    } else {
      body = Center(
        child: AspectRatio(
          aspectRatio: controller.value.aspectRatio,
          child: Stack(
            alignment: Alignment.center,
            children: [
              VideoPlayer(controller),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: VideoProgressIndicator(
                  controller,
                  allowScrubbing: true,
                  colors: const VideoProgressColors(
                    playedColor: Colors.white,
                    bufferedColor: Colors.white38,
                    backgroundColor: Colors.white24,
                  ),
                ),
              ),
              IconButton(
                iconSize: 56,
                color: Colors.white70,
                icon: Icon(
                  controller.value.isPlaying
                      ? Icons.pause_circle_filled
                      : Icons.play_circle_filled,
                ),
                onPressed: () {
                  setState(() {
                    controller.value.isPlaying
                        ? controller.pause()
                        : controller.play();
                  });
                },
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(child: body),
          _PreviewCloseButton(onPressed: () => Navigator.pop(context)),
          _PreviewDownloadButton(onPressed: () => _downloadUrl(widget.url)),
        ],
      ),
    );
  }
}

class _PreviewCloseButton extends StatelessWidget {
  final VoidCallback onPressed;

  const _PreviewCloseButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 8,
      left: 8,
      child: IconButton(
        icon: const Icon(Icons.close, color: Colors.white),
        onPressed: onPressed,
      ),
    );
  }
}

class _PreviewDownloadButton extends StatelessWidget {
  final VoidCallback onPressed;

  const _PreviewDownloadButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 8,
      right: 8,
      child: IconButton(
        icon: const Icon(Icons.download_rounded, color: Colors.white),
        onPressed: onPressed,
      ),
    );
  }
}

class _VideoBase extends StatelessWidget {
  const _VideoBase();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 200,
      height: 150,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
    );
  }
}

class _MediaPlaceholder extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _MediaPlaceholder({
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 200,
      height: 120,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: color),
          const SizedBox(height: 4),
          Text(label, style: TextStyle(color: color)),
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  final String? url;
  final double radius;

  const _Avatar({this.url, this.radius = 20});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fallback = CircleAvatar(
      radius: radius,
      backgroundColor: cs.surfaceContainerHighest,
      child: Icon(Icons.person_outline, color: cs.onSurfaceVariant),
    );
    if (url == null || url!.isEmpty) return fallback;
    return ClipOval(
      child: Image.network(
        url!,
        width: radius * 2,
        height: radius * 2,
        fit: BoxFit.cover,
        webHtmlElementStrategy: WebHtmlElementStrategy.prefer,
        errorBuilder: (_, __, ___) => fallback,
      ),
    );
  }
}

class _WebFriendPage extends StatefulWidget {
  const _WebFriendPage();

  @override
  State<_WebFriendPage> createState() => _WebFriendPageState();
}

class _WebFriendPageState extends State<_WebFriendPage> {
  bool _loading = true;
  List<Map<String, dynamic>> _friends = const [];
  int _pending = 0;
  StreamSubscription<void>? _friendshipSub;

  @override
  void initState() {
    super.initState();
    _friendshipSub = IMService.instance.friendshipStream.listen((_) => _load());
    _load();
  }

  @override
  void dispose() {
    _friendshipSub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final friends = await IMService.instance.getFriendListAsMaps();
    final apps = await IMService.instance.getIncomingFriendApplicationsAsMaps();
    if (!mounted) return;
    setState(() {
      _friends = friends;
      _pending = apps.where((a) => _toInt(a['handle_result']) == 0).length;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('联系人'),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: '加好友',
            icon: const Icon(Icons.person_add_alt_1),
            onPressed: () => Navigator.of(context)
                .push(
                  MaterialPageRoute(builder: (_) => const _WebAddFriendPage()),
                )
                .then((_) => _load()),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                children: [
                  ListTile(
                    leading: CircleAvatar(
                      backgroundColor: cs.primaryContainer,
                      child: Icon(
                        Icons.fingerprint,
                        color: cs.onPrimaryContainer,
                      ),
                    ),
                    title: const Text('我的 ID'),
                    subtitle: SelectableText(
                      IMService.instance.currentUserId ?? '',
                    ),
                    trailing: IconButton(
                      tooltip: '复制',
                      icon: const Icon(Icons.copy, size: 18),
                      onPressed: () async {
                        await Clipboard.setData(
                          ClipboardData(
                            text: IMService.instance.currentUserId ?? '',
                          ),
                        );
                      },
                    ),
                  ),
                  ListTile(
                    leading: CircleAvatar(
                      backgroundColor: cs.tertiaryContainer,
                      child: Icon(
                        Icons.person_add,
                        color: cs.onTertiaryContainer,
                      ),
                    ),
                    title: const Text('新的朋友'),
                    trailing: _pending > 0
                        ? Badge(label: Text('$_pending'))
                        : const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context)
                        .push(
                          MaterialPageRoute(
                            builder: (_) => const _WebFriendApplicationPage(),
                          ),
                        )
                        .then((_) => _load()),
                  ),
                  const Divider(height: 1),
                  if (_friends.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 80),
                      child: Center(child: Text('暂无好友')),
                    )
                  else
                    for (final f in _friends)
                      ListTile(
                        leading: _Avatar(url: f['face_url']?.toString()),
                        title: Text(_friendName(f)),
                        subtitle: Text(f['user_id']?.toString() ?? ''),
                        onTap: () {
                          final userID = f['user_id']?.toString() ?? '';
                          if (userID.isEmpty) return;
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => _WebChatPage(
                                conversation: {
                                  'conversation_id': 'single_$userID',
                                  'conversation_type': 1,
                                  'user_id': userID,
                                  'show_name': _friendName(f),
                                  'face_url': f['face_url']?.toString() ?? '',
                                },
                              ),
                            ),
                          );
                        },
                      ),
                ],
              ),
            ),
    );
  }
}

class _WebFriendApplicationPage extends StatefulWidget {
  const _WebFriendApplicationPage();

  @override
  State<_WebFriendApplicationPage> createState() =>
      _WebFriendApplicationPageState();
}

class _WebFriendApplicationPageState extends State<_WebFriendApplicationPage> {
  bool _loading = true;
  List<Map<String, dynamic>> _apps = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final apps = await IMService.instance.getIncomingFriendApplicationsAsMaps();
    if (!mounted) return;
    setState(() {
      _apps = apps;
      _loading = false;
    });
  }

  Future<void> _handle(String userID, bool accept) async {
    final ok = accept
        ? await IMService.instance.acceptFriendApplication(fromUserID: userID)
        : await IMService.instance.rejectFriendApplication(fromUserID: userID);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(ok ? '已处理' : '处理失败')));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('新的朋友'), centerTitle: true),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                children: [
                  if (_apps.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 80),
                      child: Center(child: Text('暂无好友申请')),
                    )
                  else
                    for (final app in _apps)
                      ListTile(
                        leading: _Avatar(url: app['from_face_url']?.toString()),
                        title: Text(
                          app['from_nickname']?.toString().isNotEmpty == true
                              ? app['from_nickname'].toString()
                              : app['from_user_id']?.toString() ?? '',
                        ),
                        subtitle: Text(app['req_msg']?.toString() ?? ''),
                        trailing: _toInt(app['handle_result']) == 0
                            ? Wrap(
                                spacing: 8,
                                children: [
                                  TextButton(
                                    onPressed: () => _handle(
                                      app['from_user_id']?.toString() ?? '',
                                      false,
                                    ),
                                    child: const Text('拒绝'),
                                  ),
                                  FilledButton(
                                    onPressed: () => _handle(
                                      app['from_user_id']?.toString() ?? '',
                                      true,
                                    ),
                                    child: const Text('同意'),
                                  ),
                                ],
                              )
                            : Text(
                                _toInt(app['handle_result']) == 1
                                    ? '已同意'
                                    : '已拒绝',
                              ),
                      ),
                ],
              ),
            ),
    );
  }
}

class _WebAddFriendPage extends StatefulWidget {
  const _WebAddFriendPage();

  @override
  State<_WebAddFriendPage> createState() => _WebAddFriendPageState();
}

class _WebAddFriendPageState extends State<_WebAddFriendPage> {
  final _controller = TextEditingController();
  bool _loading = false;
  List<Map<String, dynamic>> _users = const [];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _controller.text.trim();
    if (q.length < 2) return;
    setState(() => _loading = true);
    final users = await IMService.instance.searchUsers(q);
    if (!mounted) return;
    setState(() {
      _users = users;
      _loading = false;
    });
  }

  Future<void> _add(String userID) async {
    final ok = await IMService.instance.sendFriendApplication(
      userID: userID,
      reqMsg: '你好，我想添加你为好友',
    );
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(ok ? '好友申请已发送' : '发送失败')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('加好友'), centerTitle: true),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _search(),
                    decoration: const InputDecoration(
                      hintText: '搜索用户 ID / 邮箱 / 昵称',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: _loading ? null : _search,
                  icon: _loading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.search),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _users.length,
              itemBuilder: (context, index) {
                final u = _users[index];
                final userID =
                    u['im_user_id']?.toString() ??
                    u['user_id']?.toString() ??
                    u['id']?.toString() ??
                    u['userID']?.toString() ??
                    '';
                final name =
                    u['nickname']?.toString() ??
                    u['display_name']?.toString() ??
                    u['username']?.toString() ??
                    userID;
                return ListTile(
                  leading: _Avatar(
                    url:
                        u['face_url']?.toString() ??
                        u['avatar_url']?.toString(),
                  ),
                  title: Text(name),
                  subtitle: Text(userID),
                  trailing: FilledButton(
                    onPressed: userID.isEmpty ? null : () => _add(userID),
                    child: const Text('添加'),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

String _friendName(Map<String, dynamic> f) {
  return f['remark']?.toString().isNotEmpty == true
      ? f['remark'].toString()
      : f['nickname']?.toString().isNotEmpty == true
      ? f['nickname'].toString()
      : f['user_id']?.toString() ?? '';
}

int _toInt(Object? value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}

String _firstNonEmpty(List<Object?> values) {
  for (final value in values) {
    final text = value?.toString() ?? '';
    if (text.isNotEmpty) return text;
  }
  return '';
}

String _fmtDuration(int seconds) {
  final m = seconds ~/ 60;
  final s = seconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

class _WebImUploadResult {
  final String publicUrl;
  final String key;

  const _WebImUploadResult({required this.publicUrl, required this.key});
}

class _WebImMediaUploader {
  static Future<_WebImUploadResult?> uploadBytes(
    Uint8List bytes, {
    required String fileName,
    required String purpose,
    String? contentType,
  }) async {
    final token = AuthService.token;
    if (token == null) throw Exception('Please sign in first');
    final ext = _extension(fileName, contentType);
    final type = contentType ?? _fallbackContentType(purpose, ext);
    final signResp = await http
        .post(
          Uri.parse('${AppConfig.backendUrl}/api/im/media/upload-url'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: json.encode({
            'purpose': purpose,
            'ext': ext,
            'content_type': type,
            'size': bytes.length,
          }),
        )
        .timeout(const Duration(seconds: 10));
    if (signResp.statusCode != 200) {
      throw Exception('上传授权失败 ${signResp.statusCode}');
    }
    final data = json.decode(signResp.body) as Map<String, dynamic>;
    final putUrl = data['put_url']?.toString() ?? '';
    final publicUrl = data['public_url']?.toString() ?? '';
    final key = data['key']?.toString() ?? '';
    if (putUrl.isEmpty || publicUrl.isEmpty || key.isEmpty) {
      throw Exception('上传授权响应缺字段');
    }
    final putResp = await http
        .put(Uri.parse(putUrl), headers: {'Content-Type': type}, body: bytes)
        .timeout(const Duration(minutes: 2));
    if (putResp.statusCode < 200 || putResp.statusCode >= 300) {
      throw Exception('上传失败 ${putResp.statusCode}');
    }
    return _WebImUploadResult(publicUrl: publicUrl, key: key);
  }

  static String _extension(String fileName, String? contentType) {
    final clean = fileName.split('?').first;
    final dot = clean.lastIndexOf('.');
    if (dot >= 0 && dot < clean.length - 1) {
      return clean.substring(dot + 1).toLowerCase();
    }
    final type = contentType ?? '';
    if (type.contains('png')) return 'png';
    if (type.contains('webp')) return 'webp';
    if (type.contains('gif')) return 'gif';
    if (type.contains('quicktime')) return 'mov';
    if (type.contains('webm')) return 'webm';
    if (type.startsWith('video/')) return 'mp4';
    return 'jpg';
  }

  static String _fallbackContentType(String purpose, String ext) {
    if (purpose == 'video') {
      return switch (ext) {
        'mov' => 'video/quicktime',
        'webm' => 'video/webm',
        _ => 'video/mp4',
      };
    }
    return switch (ext) {
      'png' => 'image/png',
      'webp' => 'image/webp',
      'gif' => 'image/gif',
      _ => 'image/jpeg',
    };
  }
}

Future<void> _openUrl(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return;
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}
