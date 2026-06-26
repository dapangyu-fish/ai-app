// 框架层「敏感能力授权器」
// ───────────────────────────────────────────────
// JSON-APP 不可信：调用 @get_auth_token / @get_user_info 会把登录凭证 / 账号信息
// 暴露给 JSON 配置，进而可能被发往第三方服务器（见 docs/interpreter-game-security-review.md C1）。
// 本授权器在这些调用点按 appId 弹窗授权：
//   - 单次运行：仅本次运行允许，重新打开会再次询问。
//   - 始终允许：持久化，不再询问；可勾选「仅限当前版本」，不勾则对该 app 所有版本生效。
//   - 拒绝：本次运行内拒绝。
// 弹窗带第三方风险提示。无法弹窗时 fail-closed（拒绝），保证凭证不会在无授权时外泄。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 框架里会把用户隐私 / 凭证暴露给 JSON-APP 的敏感调用点。
enum SensitiveCapability { authToken, userInfo }

extension SensitiveCapabilityMeta on SensitiveCapability {
  /// 持久化 / 缓存用的稳定 key。
  String get storageKey {
    switch (this) {
      case SensitiveCapability.authToken:
        return 'auth_token';
      case SensitiveCapability.userInfo:
        return 'user_info';
    }
  }

  String get title {
    switch (this) {
      case SensitiveCapability.authToken:
        return '登录凭证（Token）';
      case SensitiveCapability.userInfo:
        return '账号信息';
    }
  }

  String get detail {
    switch (this) {
      case SensitiveCapability.authToken:
        return '该应用请求读取你的登录凭证（access token）。凭证可用于以你的身份访问服务。';
      case SensitiveCapability.userInfo:
        return '该应用请求读取你的账号信息（如昵称、头像、邮箱等）。';
    }
  }
}

enum _Decision { once, always, deny }

class _DialogResult {
  final _Decision decision;
  final bool fixedVersion;
  const _DialogResult(this.decision, this.fixedVersion);
}

/// 按 (appId, capability) 维度做授权决策。一个 interpreter 持一个实例。
class TokenAuthorizer {
  static const String _prefsKey = 'json_app_sensitive_grants_v1';

  /// appId -> capabilityKey -> { scope: 'all' | 'version', version?: String }
  Map<String, dynamic>? _persisted;
  bool _loaded = false;

  // 「单次运行」缓存：loadConfig（切 app / 重新运行）时清空。
  final Set<String> _runAllow = {};
  final Set<String> _runDeny = {};
  // 同一 (appId, capability) 并发请求时复用同一个弹窗，避免叠弹。
  final Map<String, Future<bool>> _inflight = {};

  // 跨能力串行化：保证任意时刻最多只有一个授权弹窗，
  // 避免 @parallel 里 authToken + userInfo 两个不同能力同时弹窗相互叠压。
  Future<void> _dialogLock = Future.value();

  /// 新一次 app 运行开始：清掉「单次运行」授权（持久化的「始终允许」保留）。
  void resetRunGrants() {
    _runAllow.clear();
    _runDeny.clear();
    _inflight.clear();
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    final prev = _dialogLock;
    final completer = Completer<void>();
    _dialogLock = completer.future;
    return prev.then((_) => action()).whenComplete(completer.complete);
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      _persisted = raw == null
          ? <String, dynamic>{}
          : (jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      _persisted = <String, dynamic>{};
    }
    _loaded = true;
  }

  bool _persistedAllows(String appId, String capKey, String version) {
    final app = _persisted?[appId];
    if (app is! Map) return false;
    final grant = app[capKey];
    if (grant is! Map) return false;
    final scope = grant['scope']?.toString();
    if (scope == 'all') return true;
    if (scope == 'version') return grant['version']?.toString() == version;
    return false;
  }

  Future<void> _persistAlways(
    String appId,
    String capKey,
    String version,
    bool fixedVersion,
  ) async {
    await _ensureLoaded();
    final map = _persisted ??= <String, dynamic>{};
    final app =
        (map[appId] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    app[capKey] = fixedVersion
        ? {'scope': 'version', 'version': version}
        : {'scope': 'all'};
    map[appId] = app;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, jsonEncode(map));
    } catch (e) {
      // 持久化失败不阻塞本次授权——本次仍按用户选择放行（已写入运行缓存），
      // 但「始终允许」会退化为「单次运行」，下次启动会再次询问。
      debugPrint('[TokenAuthorizer] 授权持久化失败，本次降级为单次运行: $e');
    }
  }

  /// 撤销某 app 的全部已授权（给后续「管理应用权限」界面预留）。
  Future<void> revokeApp(String appId) async {
    await _ensureLoaded();
    _persisted?.remove(appId);
    _runAllow.removeWhere((k) => k.startsWith('$appId|'));
    _runDeny.removeWhere((k) => k.startsWith('$appId|'));
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, jsonEncode(_persisted ?? {}));
    } catch (_) {}
  }

  /// 返回是否授权。同一 (appId, capability) 的并发调用复用同一个弹窗结果。
  Future<bool> authorize({
    required String appId,
    required String appVersion,
    required String appName,
    required SensitiveCapability capability,
    required BuildContext? context,
  }) {
    final runKey = '$appId|${capability.storageKey}';
    final existing = _inflight[runKey];
    if (existing != null) return existing;
    final fut = _authorize(
      appId,
      appVersion,
      appName,
      capability,
      runKey,
      context,
    );
    _inflight[runKey] = fut;
    return fut.whenComplete(() => _inflight.remove(runKey));
  }

  Future<bool> _authorize(
    String appId,
    String appVersion,
    String appName,
    SensitiveCapability capability,
    String runKey,
    BuildContext? context,
  ) async {
    await _ensureLoaded();
    final capKey = capability.storageKey;

    // 1. 始终允许（持久化）。
    if (_persistedAllows(appId, capKey, appVersion)) return true;
    // 2. 单次运行缓存。
    if (_runAllow.contains(runKey)) return true;
    if (_runDeny.contains(runKey)) return false;

    // 3. 弹窗询问。无 context 时 fail-closed，且不缓存，留待有 context 时再问。
    final ctx = context;
    if (ctx == null || !ctx.mounted) return false;

    // 串行化：排队等上一个授权弹窗关闭，避免多个弹窗叠压。
    final result = await _serialize<_DialogResult?>(() async {
      if (!ctx.mounted) return null;
      return showDialog<_DialogResult>(
        context: ctx,
        barrierDismissible: false,
        builder: (_) => _TokenAuthDialog(
          appName: appName,
          appId: appId,
          appVersion: appVersion,
          capability: capability,
        ),
      );
    });

    switch (result?.decision) {
      case _Decision.always:
        _runAllow.add(runKey);
        await _persistAlways(appId, capKey, appVersion, result!.fixedVersion);
        return true;
      case _Decision.once:
        _runAllow.add(runKey);
        return true;
      case _Decision.deny:
      case null:
        _runDeny.add(runKey);
        return false;
    }
  }
}

class _TokenAuthDialog extends StatefulWidget {
  final String appName;
  final String appId;
  final String appVersion;
  final SensitiveCapability capability;

  const _TokenAuthDialog({
    required this.appName,
    required this.appId,
    required this.appVersion,
    required this.capability,
  });

  @override
  State<_TokenAuthDialog> createState() => _TokenAuthDialogState();
}

class _TokenAuthDialogState extends State<_TokenAuthDialog> {
  // 默认不勾 = 对所有版本生效。
  bool _fixedVersion = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasVersion = widget.appVersion.trim().isNotEmpty;
    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.privacy_tip_outlined, color: scheme.error),
          const SizedBox(width: 8),
          const Expanded(child: Text('权限请求')),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text.rich(
              TextSpan(
                children: [
                  const TextSpan(text: '应用 '),
                  TextSpan(
                    text: widget.appName,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  TextSpan(text: ' 请求访问你的「${widget.capability.title}」。'),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              widget.capability.detail,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: scheme.errorContainer.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 18,
                    color: scheme.error,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '风险提示：授权后，该应用可能会把这些信息发送到第三方服务器，'
                      '从而可能导致你的账号或隐私泄漏。请仅在你信任该应用时授权。',
                      style: TextStyle(
                        color: scheme.onErrorContainer,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              dense: true,
              value: _fixedVersion,
              onChanged: (v) => setState(() => _fixedVersion = v ?? false),
              title: Text(
                hasVersion ? '仅限当前版本（v${widget.appVersion}）' : '仅限当前版本',
              ),
              subtitle: const Text(
                '不勾选则对该应用所有版本生效',
                style: TextStyle(fontSize: 11),
              ),
            ),
            Text(
              'App ID: ${widget.appId}',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 10),
            ),
          ],
        ),
      ),
      actionsOverflowButtonSpacing: 4,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(
            context,
          ).pop(const _DialogResult(_Decision.deny, false)),
          child: Text('拒绝', style: TextStyle(color: scheme.error)),
        ),
        TextButton(
          onPressed: () => Navigator.of(
            context,
          ).pop(_DialogResult(_Decision.once, _fixedVersion)),
          child: const Text('仅本次运行'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(
            context,
          ).pop(_DialogResult(_Decision.always, _fixedVersion)),
          child: const Text('始终允许'),
        ),
      ],
    );
  }
}
