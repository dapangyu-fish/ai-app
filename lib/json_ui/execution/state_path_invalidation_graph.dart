import 'dart:collection';

import 'package:flutter/foundation.dart';

/// App-scoped invalidation graph for compiled global-state dependencies.
///
/// Dependency and write paths are canonical dot paths such as
/// `global.profile.name`. Parent and child paths overlap: replacing
/// `global.profile` invalidates readers of `global.profile.name`, while writing
/// `global.profile.name` invalidates readers of `global.profile`.
final class StatePathInvalidationGraph {
  final HashMap<Object, _RevisionSignal> _signalsByOwner =
      HashMap<Object, _RevisionSignal>.identity();
  final Set<_RevisionSignal> _allSignals = HashSet<_RevisionSignal>.identity();
  final Set<_RevisionSignal> _anyGlobalWriteSignals =
      HashSet<_RevisionSignal>.identity();
  final _PathNode _root = _PathNode();

  ValueListenable<int> signalFor({
    required Object owner,
    required Set<String> paths,
    required bool anyGlobalWrite,
  }) {
    final existing = _signalsByOwner[owner];
    if (existing != null) return existing;

    final signal = _RevisionSignal();
    _signalsByOwner[owner] = signal;
    _allSignals.add(signal);
    if (anyGlobalWrite) {
      _anyGlobalWriteSignals.add(signal);
    }
    for (final path in paths) {
      final segments = _segments(path);
      if (segments.isEmpty) {
        _anyGlobalWriteSignals.add(signal);
        continue;
      }
      var node = _root;
      for (final segment in segments) {
        node = node.children.putIfAbsent(segment, _PathNode.new);
      }
      node.terminals.add(signal);
    }
    return signal;
  }

  /// Invalidates every dependency which overlaps [canonicalGlobalPath].
  void didWrite(String canonicalGlobalPath) {
    final affected = HashSet<_RevisionSignal>.identity()
      ..addAll(_anyGlobalWriteSignals);
    final segments = _segments(canonicalGlobalPath);
    if (segments.isEmpty) {
      affected.addAll(_allSignals);
    } else {
      var node = _root;
      affected.addAll(node.terminals);
      var reachedWriteNode = true;
      for (final segment in segments) {
        final child = node.children[segment];
        if (child == null) {
          reachedWriteNode = false;
          break;
        }
        node = child;
        affected.addAll(node.terminals);
      }
      if (reachedWriteNode) {
        _collectSubtreeTerminals(node, affected);
      }
    }
    for (final signal in affected) {
      signal.bump();
    }
  }

  /// Forces every compiled host and screen fallback listener to rebuild.
  void invalidateAll() {
    for (final signal in List<_RevisionSignal>.of(_allSignals)) {
      signal.bump();
    }
  }

  static List<String> _segments(String path) {
    final normalized = path.startsWith(r'$.') ? path.substring(2) : path;
    if (normalized.isEmpty || normalized == 'global') {
      return normalized.isEmpty ? const <String>[] : const <String>['global'];
    }
    return normalized
        .split('.')
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
  }

  static void _collectSubtreeTerminals(
    _PathNode node,
    Set<_RevisionSignal> output,
  ) {
    output.addAll(node.terminals);
    for (final child in node.children.values) {
      _collectSubtreeTerminals(child, output);
    }
  }
}

final class _PathNode {
  final Map<String, _PathNode> children = <String, _PathNode>{};
  final Set<_RevisionSignal> terminals = HashSet<_RevisionSignal>.identity();
}

final class _RevisionSignal extends ChangeNotifier
    implements ValueListenable<int> {
  int _revision = 0;

  @override
  int get value => _revision;

  void bump() {
    _revision++;
    notifyListeners();
  }
}
