import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import '../json_ui/asset_cache.dart';
import '../json_ui/asset_manager.dart';

class GameAudioController {
  GameAudioController({required this.assetManager});

  final JsonAppAssetManager assetManager;
  final Map<String, _AudioSpec> _catalog = {};
  final Map<String, AudioPlayer> _loopingPlayers = {};
  final Set<AudioPlayer> _oneShotPlayers = {};
  // remote url -> 本地缓存文件路径。音频不能每次播放都联网流式拉取：SFX 一次
  // 跨区 HTTPS 拉取就是数秒延迟甚至静音。configure() 时经 AssetCache 预取一次，
  // 之后全部走本地文件。
  final Map<String, String> _localPaths = {};
  final Set<String> _fetching = {};
  bool _disposed = false;

  void configure(dynamic raw) {
    if (_disposed) return;
    _catalog.clear();
    if (raw is! Map) return;
    final baseUrl = raw['base_url']?.toString();
    _readGroup(raw['tracks'], baseUrl: baseUrl, defaultLoop: true);
    _readGroup(raw['sounds'], baseUrl: baseUrl, defaultLoop: false);
    for (final spec in _catalog.values) {
      _prefetch(spec.source);
    }
  }

  bool _isRemote(String source) {
    final uri = Uri.tryParse(source);
    return uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
  }

  void _prefetch(String source) {
    if (!_isRemote(source)) return;
    if (_localPaths.containsKey(source) || _fetching.contains(source)) return;
    _fetching.add(source);
    unawaited(() async {
      try {
        final cached = await AssetCache.instance.getBytes(
          source,
          namespace: assetManager.namespace,
        );
        final path = cached.path;
        if (path != null && !_disposed) _localPaths[source] = path;
      } catch (e) {
        debugPrint('[game_audio] prefetch failed: $source $e');
      } finally {
        _fetching.remove(source);
      }
    }());
  }

  bool play(
    String idOrSource, {
    bool? loop,
    double? volume,
    bool restart = true,
  }) {
    if (_disposed) return false;
    if (idOrSource.isEmpty) return false;
    final spec = _catalog[idOrSource] ?? _AudioSpec(source: idOrSource);
    final shouldLoop = loop ?? spec.loop;
    final effectiveVolume = (volume ?? spec.volume).clamp(0, 1).toDouble();

    if (shouldLoop) {
      // BGM：本地未就绪时允许 UrlSource 流式起播（只拉一次，晚几秒可接受）
      _prefetch(spec.source);
      final player = _loopingPlayers.putIfAbsent(idOrSource, AudioPlayer.new);
      unawaited(_playLooping(player, spec.source, effectiveVolume, restart));
      return true;
    }

    // 一次性音效：只从本地缓存播。未就绪就触发预取并跳过本次 ——
    // 迟到几秒的枪声比静音更糟；预取完成后（通常在开局数秒内）恢复即时播放。
    if (_isRemote(spec.source) && !_localPaths.containsKey(spec.source)) {
      _prefetch(spec.source);
      return false;
    }
    final player = AudioPlayer();
    _oneShotPlayers.add(player);
    player.onPlayerComplete.listen((_) {
      _oneShotPlayers.remove(player);
      unawaited(player.dispose());
    });
    unawaited(_playOneShot(player, spec.source, effectiveVolume));
    return true;
  }

  bool stop([String? id]) {
    if (_disposed) return false;
    if (id == null || id.isEmpty) {
      for (final player in _loopingPlayers.values) {
        unawaited(player.stop());
      }
      for (final player in _oneShotPlayers.toList(growable: false)) {
        unawaited(player.stop());
        unawaited(player.dispose());
      }
      _oneShotPlayers.clear();
      return true;
    }
    final player = _loopingPlayers[id];
    if (player == null) return false;
    unawaited(player.stop());
    return true;
  }

  bool pause([String? id]) {
    if (_disposed) return false;
    if (id == null || id.isEmpty) {
      for (final player in _loopingPlayers.values) {
        unawaited(player.pause());
      }
      return true;
    }
    final player = _loopingPlayers[id];
    if (player == null) return false;
    unawaited(player.pause());
    return true;
  }

  bool resume([String? id]) {
    if (_disposed) return false;
    if (id == null || id.isEmpty) {
      for (final player in _loopingPlayers.values) {
        unawaited(player.resume());
      }
      return true;
    }
    final player = _loopingPlayers[id];
    if (player == null) return false;
    unawaited(player.resume());
    return true;
  }

  bool setVolume(String id, double volume) {
    if (_disposed) return false;
    final player = _loopingPlayers[id];
    if (player == null) return false;
    unawaited(player.setVolume(volume.clamp(0, 1).toDouble()));
    return true;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final player in _loopingPlayers.values) {
      unawaited(player.dispose());
    }
    _loopingPlayers.clear();
    for (final player in _oneShotPlayers.toList(growable: false)) {
      unawaited(player.dispose());
    }
    _oneShotPlayers.clear();
  }

  void _readGroup(dynamic raw, {String? baseUrl, required bool defaultLoop}) {
    if (raw is! Map) return;
    raw.forEach((key, value) {
      final id = key.toString();
      if (id.isEmpty) return;
      if (value is String) {
        _catalog[id] = _AudioSpec(
          source: assetManager.resolve(value, baseUrl: baseUrl),
          loop: defaultLoop,
        );
      } else if (value is Map) {
        final source = value['src']?.toString() ?? value['source']?.toString();
        if (source == null || source.isEmpty) return;
        _catalog[id] = _AudioSpec(
          source: assetManager.resolve(
            source,
            baseUrl: value['base_url']?.toString() ?? baseUrl,
          ),
          loop: value['loop'] is bool ? value['loop'] == true : defaultLoop,
          volume: _readVolume(value['volume']),
        );
      }
    });
  }

  Future<void> _playLooping(
    AudioPlayer player,
    String source,
    double volume,
    bool restart,
  ) async {
    try {
      await player.setReleaseMode(ReleaseMode.loop);
      await player.setVolume(volume);
      if (restart) {
        await player.stop();
        await player.play(_sourceFor(source));
      } else {
        final state = player.state;
        if (state == PlayerState.playing) return;
        await player.play(_sourceFor(source));
      }
    } catch (e) {
      debugPrint('[game_audio] play looping failed: $e');
    }
  }

  Future<void> _playOneShot(
    AudioPlayer player,
    String source,
    double volume,
  ) async {
    try {
      await player.setReleaseMode(ReleaseMode.release);
      await player.setVolume(volume);
      await player.play(_sourceFor(source));
    } catch (e) {
      debugPrint('[game_audio] play one-shot failed: $e');
      _oneShotPlayers.remove(player);
      await player.dispose();
    }
  }

  Source _sourceFor(String source) {
    final uri = Uri.tryParse(source);
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      final local = _localPaths[source];
      if (local != null) return DeviceFileSource(local);
      return UrlSource(source);
    }
    if (source.startsWith('assets/')) {
      return AssetSource(source.substring('assets/'.length));
    }
    return AssetSource(source);
  }

  static double _readVolume(dynamic value) {
    if (value is num) return value.toDouble().clamp(0, 1).toDouble();
    if (value is String) {
      return (double.tryParse(value.trim()) ?? 1).clamp(0, 1).toDouble();
    }
    return 1;
  }
}

class _AudioSpec {
  const _AudioSpec({required this.source, this.loop = false, this.volume = 1});

  final String source;
  final bool loop;
  final double volume;
}
