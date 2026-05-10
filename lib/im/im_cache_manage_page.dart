// 聊天图片缓存管理页
//
// 功能：
//   - 列出所有 IM 会话（单聊 + 群聊）
//   - 每个会话扫一遍最近 N 条消息，收集 picture / video snapshot URL
//   - 在 ImMediaCacheManager 里查每个 URL 是否有 cache + 多大，加总
//   - checkbox 选会话；"全选" / "清理选中" 两个按钮
//   - 清理 = 从 cache 里 removeFile 这些 URL 对应的本地文件
//
// 设计取舍：
//   - getAdvancedHistoryMessageList 一次拉 200 条够用；超久远的图片用户自己也不会想清
//     （而且本地 SQLite 可能也只缓存了最近这么多）。如果要"完整扫"，得分页拉到底
//     N 千条，慢且数据量大，先不做
//   - 视频本体（msg.videoElem.videoUrl）也算，但视频不走 ImMediaCacheManager
//     缓存（chewie 内部直流），所以这里不统计；只算缩略图
//   - 文件消息（filemsg）不在范围（文件用的是 OS tmp dir 自己管理）

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_openim_sdk/flutter_openim_sdk.dart';

import '../i18n/framework_strings.dart';
import 'im_cache_manager.dart';
import 'im_service.dart';

class IMCacheManagePage extends StatefulWidget {
  const IMCacheManagePage({super.key});

  @override
  State<IMCacheManagePage> createState() => _IMCacheManagePageState();
}

class _IMCacheManagePageState extends State<IMCacheManagePage> {
  bool _loading = true;
  List<_ConvoCache> _items = [];
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    setState(() {
      _loading = true;
      _items = [];
      _selected.clear();
    });

    final convos = await IMService.instance.getConversationList();
    final List<_ConvoCache> result = [];

    for (final c in convos) {
      final urls = await _collectImageUrls(c);
      int totalBytes = 0;
      final hits = <String>[]; // 命中的 URL（可被清的）
      for (final url in urls) {
        final info = await ImMediaCacheManager.instance.getFileFromCache(url);
        if (info != null) {
          try {
            totalBytes += await info.file.length();
            hits.add(url);
          } catch (_) {
            // 文件被删但元数据没清；忽略
          }
        }
      }
      if (totalBytes > 0) {
        result.add(_ConvoCache(
          conversationID: c.conversationID,
          name: c.showName ?? c.userID ?? c.groupID ?? c.conversationID,
          faceUrl: c.faceURL ?? '',
          bytes: totalBytes,
          urls: hits,
        ));
      }
    }

    // 大的排前面
    result.sort((a, b) => b.bytes.compareTo(a.bytes));

    if (!mounted) return;
    setState(() {
      _items = result;
      _loading = false;
    });
  }

  /// 扫一个会话最近的图片消息，收集 URL。
  /// 上限 200 条，覆盖大多数用户，再多走"长期累积"已经偏离设置页用法。
  Future<List<String>> _collectImageUrls(ConversationInfo c) async {
    final urls = <String>[];
    try {
      final msgs = await IMService.instance.getHistoryMessages(
        conversationID: c.conversationID,
        count: 200,
      );
      for (final m in msgs) {
        if (m.contentType == MessageType.picture) {
          final u = m.pictureElem?.bigPicture?.url ??
              m.pictureElem?.sourcePicture?.url;
          if (u != null && u.isNotEmpty) urls.add(u);
        } else if (m.contentType == MessageType.video) {
          final u = m.videoElem?.snapshotUrl;
          if (u != null && u.isNotEmpty) urls.add(u);
        }
      }
    } catch (e) {
      debugPrint('[IMCache] 扫消息失败 conv=${c.conversationID}: $e');
    }
    return urls;
  }

  Future<void> _clearSelected() async {
    final s = T.of(context);
    if (_selected.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(s.imCacheNoSelection)),
      );
      return;
    }
    int clearedBytes = 0;
    for (final cid in _selected) {
      final item = _items.firstWhere(
        (i) => i.conversationID == cid,
        orElse: () => const _ConvoCache(
          conversationID: '', name: '', faceUrl: '', bytes: 0, urls: [],
        ),
      );
      for (final url in item.urls) {
        try {
          await ImMediaCacheManager.instance.removeFile(url);
        } catch (e) {
          debugPrint('[IMCache] 清理失败 url=$url: $e');
        }
      }
      clearedBytes += item.bytes;
    }
    if (!mounted) return;
    final cleared = _formatBytes(clearedBytes);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(s.imCacheClearedToast.replaceAll('{size}', cleared))),
    );
    await _scan();
  }

  void _toggleAll() {
    setState(() {
      if (_selected.length == _items.length) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(_items.map((i) => i.conversationID));
      }
    });
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)}GB';
  }

  @override
  Widget build(BuildContext context) {
    final s = T.of(context);
    final cs = Theme.of(context).colorScheme;
    final total = _items.fold<int>(0, (a, b) => a + b.bytes);
    final allSelected = _items.isNotEmpty && _selected.length == _items.length;

    return Scaffold(
      appBar: AppBar(
        title: Text(s.imCacheManageTitle),
        centerTitle: true,
      ),
      body: _loading
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(s.imCacheLoading, style: TextStyle(color: cs.onSurfaceVariant)),
                ],
              ),
            )
          : Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  color: cs.surfaceContainerHighest,
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          s.imCacheTotal.replaceAll('{size}', _formatBytes(total)),
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      TextButton(
                        onPressed: _items.isEmpty ? null : _toggleAll,
                        child: Text(allSelected ? s.imCacheDeselectAll : s.imCacheSelectAll),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: _items.isEmpty
                      ? Center(
                          child: Text(
                            _formatBytes(0),
                            style: TextStyle(color: cs.onSurfaceVariant),
                          ),
                        )
                      : ListView.builder(
                          itemCount: _items.length,
                          itemBuilder: (_, i) {
                            final item = _items[i];
                            final checked = _selected.contains(item.conversationID);
                            return CheckboxListTile(
                              value: checked,
                              onChanged: (v) {
                                setState(() {
                                  if (v == true) {
                                    _selected.add(item.conversationID);
                                  } else {
                                    _selected.remove(item.conversationID);
                                  }
                                });
                              },
                              title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text(_formatBytes(item.bytes)),
                              controlAffinity: ListTileControlAffinity.leading,
                            );
                          },
                        ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _items.isEmpty ? null : _clearSelected,
                        child: Text(s.imCacheClearSelected),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class _ConvoCache {
  final String conversationID;
  final String name;
  final String faceUrl;
  final int bytes;
  final List<String> urls;
  const _ConvoCache({
    required this.conversationID,
    required this.name,
    required this.faceUrl,
    required this.bytes,
    required this.urls,
  });
}
