import 'dart:collection';

import '../path_plan.dart';

/// Namespace selected by the JSON App variable-path grammar.
enum VariableNamespace { global, loop, params, event, app, unqualified }

/// Load-time parsed variable reference.
///
/// The plan retains syntax only. It never retains an App state object or a
/// looked-up value, so mutable state remains observable on every evaluation.
final class VariableReadPlan {
  VariableReadPlan._({
    required this.source,
    required this.namespace,
    required this.path,
    required this.pathPlan,
  });

  factory VariableReadPlan.compile(String source) {
    var normalized = source.trim();
    if (normalized.startsWith(r'$.')) {
      normalized = normalized.substring(2);
    }

    VariableNamespace namespace;
    String path;
    if (normalized.startsWith('global.')) {
      namespace = VariableNamespace.global;
      path = normalized.substring(7);
    } else if (normalized.startsWith('loop.')) {
      namespace = VariableNamespace.loop;
      path = normalized.substring(5);
    } else if (normalized.startsWith('params.')) {
      namespace = VariableNamespace.params;
      path = normalized.substring(7);
    } else if (normalized.startsWith('event.')) {
      namespace = VariableNamespace.event;
      path = normalized.substring(6);
    } else if (normalized.startsWith('app.')) {
      namespace = VariableNamespace.app;
      path = normalized.substring(4);
    } else {
      namespace = VariableNamespace.unqualified;
      path = normalized;
    }

    return VariableReadPlan._(
      source: source,
      namespace: namespace,
      path: path,
      pathPlan: PathPlan.parse(path),
    );
  }

  final String source;
  final VariableNamespace namespace;
  final String path;
  final PathPlan pathPlan;

  bool get requiresLoopScope => namespace == VariableNamespace.loop;

  bool get requiresEventScope => namespace == VariableNamespace.event;

  /// Conservative global dependency used by the incremental-update graph.
  ///
  /// Unqualified reads first consult global state in the current interpreter,
  /// so treating them as global dependencies may over-invalidate but cannot
  /// miss a required update.
  String? get globalDependency {
    switch (namespace) {
      case VariableNamespace.global:
      case VariableNamespace.unqualified:
        return 'global.$path';
      case VariableNamespace.loop:
      case VariableNamespace.params:
      case VariableNamespace.event:
      case VariableNamespace.app:
        return null;
    }
  }
}

sealed class TemplatePart {
  const TemplatePart();
}

final class TemplateLiteralPart extends TemplatePart {
  const TemplateLiteralPart(this.value);

  final String value;
}

final class TemplateBindingPart extends TemplatePart {
  const TemplateBindingPart._({
    required this.token,
    required this.expression,
    required this.variable,
    required this.i18nKey,
  });

  factory TemplateBindingPart.compile({
    required String token,
    required String expression,
  }) {
    final trimmed = expression.trim();
    final i18nMatch = TemplatePlan.i18nCallPattern.firstMatch(trimmed);
    if (i18nMatch != null) {
      return TemplateBindingPart._(
        token: token,
        expression: trimmed,
        variable: null,
        i18nKey: i18nMatch.group(1)!,
      );
    }
    return TemplateBindingPart._(
      token: token,
      expression: trimmed,
      variable: VariableReadPlan.compile(trimmed),
      i18nKey: null,
    );
  }

  final String token;
  final String expression;
  final VariableReadPlan? variable;
  final String? i18nKey;

  bool get isI18n => i18nKey != null;

  Set<String> get globalDependencies {
    if (isI18n) return const <String>{'global.locale'};
    final dependency = variable?.globalDependency;
    return dependency == null ? const <String>{} : <String>{dependency};
  }
}

/// Immutable, load-time representation of one template string.
final class TemplatePlan {
  TemplatePlan._({
    required this.source,
    required this.parts,
    required this.exactBinding,
    required this.globalDependencies,
  });

  static final RegExp templatePattern = RegExp(r'\{\{\s*(.+?)\s*\}\}');
  static final RegExp fullTemplatePattern = RegExp(
    r'^\{\{\s*([^{}]+?)\s*\}\}$',
  );
  static final RegExp i18nCallPattern = RegExp(
    r'''^t\(\s*['"](.+?)['"]\s*\)$''',
  );

  factory TemplatePlan.compile(String source) {
    final matches = templatePattern.allMatches(source).toList(growable: false);
    if (matches.isEmpty) {
      return TemplatePlan._(
        source: source,
        parts: <TemplatePart>[TemplateLiteralPart(source)],
        exactBinding: null,
        globalDependencies: const <String>{},
      );
    }

    final parts = <TemplatePart>[];
    final dependencies = <String>{};
    var cursor = 0;
    for (final match in matches) {
      if (match.start > cursor) {
        parts.add(TemplateLiteralPart(source.substring(cursor, match.start)));
      }
      final binding = TemplateBindingPart.compile(
        token: match.group(0)!,
        expression: match.group(1)!,
      );
      parts.add(binding);
      dependencies.addAll(binding.globalDependencies);
      cursor = match.end;
    }
    if (cursor < source.length) {
      parts.add(TemplateLiteralPart(source.substring(cursor)));
    }

    TemplateBindingPart? exactBinding;
    final fullMatch = fullTemplatePattern.firstMatch(source);
    if (fullMatch != null) {
      exactBinding = TemplateBindingPart.compile(
        token: source,
        expression: fullMatch.group(1)!,
      );
      dependencies.addAll(exactBinding.globalDependencies);
    }

    return TemplatePlan._(
      source: source,
      parts: List<TemplatePart>.unmodifiable(parts),
      exactBinding: exactBinding,
      globalDependencies: Set<String>.unmodifiable(dependencies),
    );
  }

  final String source;
  final List<TemplatePart> parts;

  /// Non-null only for a single `{{ expression }}` occupying the whole string.
  final TemplateBindingPart? exactBinding;
  final Set<String> globalDependencies;

  bool get hasBindings => parts.any((part) => part is TemplateBindingPart);
}

/// Bounded cache for template strings produced dynamically after App load.
///
/// Strings present in the source JSON live in [AppExecutionPlan]; this cache
/// only covers values assembled by runtime data or dependency modules.
final class RuntimeTemplatePlanCache {
  RuntimeTemplatePlanCache({this.capacity = 512}) {
    if (capacity <= 0) {
      throw ArgumentError.value(capacity, 'capacity', 'must be positive');
    }
  }

  final int capacity;
  final LinkedHashMap<String, TemplatePlan> _plans =
      LinkedHashMap<String, TemplatePlan>();

  int get length => _plans.length;

  void clear() => _plans.clear();

  TemplatePlan planFor(String source) {
    final cached = _plans[source];
    if (cached != null) return cached;
    if (_plans.length >= capacity) {
      _plans.remove(_plans.keys.first);
    }
    final plan = TemplatePlan.compile(source);
    _plans[source] = plan;
    return plan;
  }
}
