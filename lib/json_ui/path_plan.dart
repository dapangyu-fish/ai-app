/// Result of a dot-path lookup.
///
/// [found] distinguishes a missing path from a path whose stored value is
/// `null`.
final class PathLookupResult {
  const PathLookupResult.found(this.value) : found = true;

  const PathLookupResult.notFound() : found = false, value = null;

  static const PathLookupResult missing = PathLookupResult.notFound();

  final bool found;
  final dynamic value;
}

/// Parsed, value-independent representation of a dot path.
///
/// A plan only retains string path segments and their pre-parsed list indexes.
/// It never retains a root object or a looked-up value, so the same plan always
/// observes the current contents of mutable maps and lists.
final class PathPlan {
  PathPlan._(this._segments);

  factory PathPlan.parse(String dotPath) {
    return PathPlan._([
      for (final key in dotPath.split('.'))
        _PathSegment(key, int.tryParse(key)),
    ]);
  }

  final List<_PathSegment> _segments;

  PathLookupResult lookup(Map<String, dynamic> root) {
    dynamic current = root;
    for (final segment in _segments) {
      if (current is Map<String, dynamic>) {
        if (!current.containsKey(segment.key)) {
          return PathLookupResult.missing;
        }
        current = current[segment.key];
      } else if (current is List) {
        final index = segment.listIndex;
        if (index == null || index < 0 || index >= current.length) {
          return PathLookupResult.missing;
        }
        current = current[index];
      } else {
        return PathLookupResult.missing;
      }
    }
    return PathLookupResult.found(current);
  }

  /// Writes [value] using the interpreter's existing Map/List semantics.
  ///
  /// Missing Map segments are created. Existing scalar/null intermediates,
  /// non-numeric List segments, and out-of-range List indexes are no-ops.
  /// Returns whether the final assignment was performed.
  bool write(Map<String, dynamic> root, dynamic value) {
    if (_segments.length == 1) {
      root[_segments.first.key] = value;
      return true;
    }

    dynamic current = root;
    for (var index = 0; index < _segments.length - 1; index++) {
      final segment = _segments[index];
      if (current is Map<String, dynamic>) {
        current.putIfAbsent(segment.key, () => <String, dynamic>{});
        current = current[segment.key];
      } else if (current is List) {
        final listIndex = segment.listIndex;
        if (listIndex == null || listIndex < 0 || listIndex >= current.length) {
          return false;
        }
        current = current[listIndex];
      } else {
        return false;
      }
    }

    final last = _segments.last;
    if (current is Map<String, dynamic>) {
      current[last.key] = value;
      return true;
    }
    if (current is List) {
      final listIndex = last.listIndex;
      if (listIndex == null || listIndex < 0 || listIndex >= current.length) {
        return false;
      }
      current[listIndex] = value;
      return true;
    }
    return false;
  }
}

/// Bounded cache of immutable [PathPlan]s.
///
/// Eviction is insertion ordered. App runtimes should clear the cache whenever
/// the active app changes, keeping both memory and cache ownership app-scoped.
final class PathPlanCache {
  PathPlanCache({this.capacity = 512}) {
    if (capacity <= 0) {
      throw ArgumentError.value(capacity, 'capacity', 'must be positive');
    }
  }

  final int capacity;
  final Map<String, PathPlan> _plans = <String, PathPlan>{};

  int get cachedPlanCount => _plans.length;

  void clear() => _plans.clear();

  PathLookupResult lookup(Map<String, dynamic> root, String dotPath) {
    return _planFor(dotPath).lookup(root);
  }

  bool write(Map<String, dynamic> root, String dotPath, dynamic value) {
    return _planFor(dotPath).write(root, value);
  }

  PathPlan _planFor(String dotPath) {
    final cached = _plans[dotPath];
    if (cached != null) return cached;

    if (_plans.length >= capacity) {
      _plans.remove(_plans.keys.first);
    }
    final plan = PathPlan.parse(dotPath);
    _plans[dotPath] = plan;
    return plan;
  }
}

final class _PathSegment {
  const _PathSegment(this.key, this.listIndex);

  final String key;
  final int? listIndex;
}
