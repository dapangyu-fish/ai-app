import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import '../json_ui/asset_manager.dart';

class GameAudioController {
  GameAudioController({required this.assetManager});

  final JsonAppAssetManager assetManager;
  final Map<String, _AudioSpec> _catalog = {};
  final Map<String, AudioPlayer> _loopingPlayers = {};
  final Set<AudioPlayer> _oneShotPlayers = {};
  bool _disposed = false;

  void configure(dynamic raw) {
    if (_disposed) return;
    _catalog.clear();
    if (raw is! Map) return;
    final baseUrl = raw['base_url']?.toString();
    _readGroup(raw['tracks'], baseUrl: baseUrl, defaultLoop: true);
    _readGroup(raw['sounds'], baseUrl: baseUrl, defaultLoop: false);
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
      final player = _loopingPlayers.putIfAbsent(idOrSource, AudioPlayer.new);
      unawaited(_playLooping(player, spec.source, effectiveVolume, restart));
      return true;
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
