import 'dart:convert';

import 'package:jsonlogic/jsonlogic.dart';

import 'expression_plan.dart';
import 'template_plan.dart';

/// Resolves one template leaf before JSONLogic evaluation starts.
///
/// The caller should preserve JSONLogic preprocessing semantics here. In the
/// JSON App interpreter that means resolving [TemplatePlan.source] with the
/// string-returning template resolver, not the raw-value expression resolver.
typedef CompiledJsonLogicTemplateResolver =
    dynamic Function(TemplatePlan template);

/// Preprocesses a subtree which could not be represented by the compiled plan.
///
/// This callback is responsible for recursively resolving templates and for
/// returning fresh literal containers, just like the legacy rule preprocessor.
typedef CompiledJsonLogicFallbackPreprocessor =
    dynamic Function(dynamic rawRule);

/// Optional direct evaluator for caller-defined JSONLogic operators.
///
/// Returning `handled: false` delegates to [Jsonlogic.apply]. A handled null
/// remains distinguishable from an unsupported operator.
typedef CompiledJsonLogicCustomOperatorEvaluator =
    ({bool handled, dynamic value}) Function(
      String operatorName,
      int parameterCount,
      dynamic Function(int index) evaluateAt,
    );

/// Opaque values produced by [CompiledJsonLogicEvaluator.prepare].
///
/// A nullable value is intentional: a fully compiled rule without templates or
/// fallback nodes does not allocate a preparation map.
typedef CompiledJsonLogicPreparedValues = Map<JsonLogicExpressionPlan, dynamic>;

/// Pure-Dart execution core for a compiled JSONLogic expression.
///
/// The fast path implements the scalar operators from jsonlogic 2.0.2 without
/// reconstructing a rule tree. Higher-order operators and caller-defined
/// operators are materialized and delegated to [fallbackRuntime], preserving
/// their package-specific callback behavior.
///
/// Template preprocessing historically happens before the interpreter builds
/// the JSONLogic data context. Callers which need that ordering should use:
///
/// ```dart
/// final prepared = evaluator.prepare(plan);
/// final data = buildDataContext();
/// final result = evaluator.evaluatePrepared(plan, data, prepared);
/// ```
final class CompiledJsonLogicEvaluator {
  CompiledJsonLogicEvaluator({
    required this.templateResolver,
    required this.fallbackPreprocessor,
    required this.fallbackRuntime,
    this.customOperatorEvaluator,
  });

  final CompiledJsonLogicTemplateResolver templateResolver;
  final CompiledJsonLogicFallbackPreprocessor fallbackPreprocessor;
  final Jsonlogic fallbackRuntime;
  final CompiledJsonLogicCustomOperatorEvaluator? customOperatorEvaluator;

  final Expando<bool> _requiresPreparationCache = Expando<bool>(
    'compiled-json-logic-requires-preparation',
  );

  /// Resolves all template and opaque fallback nodes in source traversal order.
  ///
  /// Returns null, without allocating a Map, when [plan] contains neither kind
  /// of node. The result is opaque and must be passed back to
  /// [evaluatePrepared] or [materialize].
  CompiledJsonLogicPreparedValues? prepare(JsonLogicExpressionPlan plan) {
    if (!_requiresPreparation(plan)) return null;
    final prepared = Map<JsonLogicExpressionPlan, dynamic>.identity();
    _preparePlan(plan, prepared);
    return prepared;
  }

  /// Convenience entry point when data is already available.
  ///
  /// Use the explicit [prepare]/[evaluatePrepared] pair when template
  /// resolution must happen before constructing [data].
  dynamic evaluate(JsonLogicExpressionPlan plan, dynamic data) {
    final prepared = prepare(plan);
    return evaluatePrepared(plan, data, prepared);
  }

  /// Evaluates [plan] using values previously returned by [prepare].
  dynamic evaluatePrepared(
    JsonLogicExpressionPlan plan,
    dynamic data,
    CompiledJsonLogicPreparedValues? prepared,
  ) {
    return _evaluatePlan(plan, data, prepared);
  }

  /// Reconstructs one rule or literal subtree with its original scalar/List
  /// parameter shape.
  ///
  /// Every represented List or Map is newly allocated. This is required
  /// because the legacy template preprocessor also returns fresh containers.
  dynamic materialize(
    JsonLogicExpressionPlan plan,
    CompiledJsonLogicPreparedValues? prepared,
  ) {
    return _materializePlan(plan, prepared);
  }

  bool _requiresPreparation(JsonLogicExpressionPlan plan) {
    final cached = _requiresPreparationCache[plan];
    if (cached != null) return cached;

    final bool result;
    if (plan is JsonLogicTemplatePlan || plan is JsonLogicFallbackPlan) {
      result = true;
    } else if (plan is JsonLogicLiteralListPlan) {
      result = plan.items.any(_requiresPreparation);
    } else if (plan is JsonLogicLiteralMapPlan) {
      result = plan.values.values.any(_requiresPreparation);
    } else if (plan is JsonLogicVariablePlan) {
      final defaultValue = plan.defaultValue;
      result = defaultValue != null && _requiresPreparation(defaultValue);
    } else if (plan is JsonLogicOperatorPlan) {
      result = plan.parameters.any(_requiresPreparation);
    } else if (plan is JsonLogicMultiAndPlan) {
      result = plan.entries.any(_requiresPreparation);
    } else {
      result = false;
    }
    _requiresPreparationCache[plan] = result;
    return result;
  }

  void _preparePlan(
    JsonLogicExpressionPlan plan,
    CompiledJsonLogicPreparedValues prepared,
  ) {
    if (plan is JsonLogicTemplatePlan) {
      prepared[plan] = templateResolver(plan.template);
      return;
    }
    if (plan is JsonLogicLiteralListPlan) {
      for (final item in plan.items) {
        _preparePlan(item, prepared);
      }
      return;
    }
    if (plan is JsonLogicLiteralMapPlan) {
      for (final value in plan.values.values) {
        _preparePlan(value, prepared);
      }
      return;
    }
    if (plan is JsonLogicVariablePlan) {
      final defaultValue = plan.defaultValue;
      if (defaultValue != null) {
        _preparePlan(defaultValue, prepared);
      }
      return;
    }
    if (plan is JsonLogicOperatorPlan) {
      for (final parameter in plan.parameters) {
        _preparePlan(parameter, prepared);
      }
      return;
    }
    if (plan is JsonLogicMultiAndPlan) {
      for (final entry in plan.entries) {
        _preparePlan(entry, prepared);
      }
      return;
    }
    if (plan is JsonLogicFallbackPlan) {
      prepared[plan] = fallbackPreprocessor(plan.rawRule);
    }
  }

  dynamic _evaluatePlan(
    JsonLogicExpressionPlan plan,
    dynamic data,
    CompiledJsonLogicPreparedValues? prepared,
  ) {
    if (plan is JsonLogicConstantPlan) return plan.value;
    if (plan is JsonLogicTemplatePlan) {
      return _preparedValue(plan, prepared);
    }
    if (plan is JsonLogicLiteralListPlan) {
      return <dynamic>[
        for (final item in plan.items) _materializePlan(item, prepared),
      ];
    }
    if (plan is JsonLogicLiteralMapPlan) {
      return <String, dynamic>{
        for (final entry in plan.values.entries)
          entry.key: _materializePlan(entry.value, prepared),
      };
    }
    if (plan is JsonLogicVariablePlan) {
      final found = _findVariable(plan.key, data, segments: plan.segments);
      if (!found.$2) return found.$1;
      final defaultValue = plan.defaultValue;
      return defaultValue == null
          ? null
          : _evaluatePlan(defaultValue, data, prepared);
    }
    if (plan is JsonLogicMultiAndPlan) {
      for (final entry in plan.entries) {
        final value = _evaluatePlan(entry, data, prepared);
        if (!_truth(value)) return false;
      }
      return true;
    }
    if (plan is JsonLogicFallbackPlan) {
      return fallbackRuntime.apply(_preparedValue(plan, prepared), data);
    }
    if (plan is JsonLogicOperatorPlan) {
      return _evaluateOperator(plan, data, prepared);
    }
    return null;
  }

  dynamic _materializePlan(
    JsonLogicExpressionPlan plan,
    CompiledJsonLogicPreparedValues? prepared,
  ) {
    if (plan is JsonLogicConstantPlan) return plan.value;
    if (plan is JsonLogicTemplatePlan) {
      return _preparedValue(plan, prepared);
    }
    if (plan is JsonLogicLiteralListPlan) {
      return <dynamic>[
        for (final item in plan.items) _materializePlan(item, prepared),
      ];
    }
    if (plan is JsonLogicLiteralMapPlan) {
      return <String, dynamic>{
        for (final entry in plan.values.entries)
          entry.key: _materializePlan(entry.value, prepared),
      };
    }
    if (plan is JsonLogicVariablePlan) {
      final rawParameters = plan.rawRule['var'];
      final materializedParameters = <dynamic>[
        plan.key,
        if (plan.defaultValue case final defaultValue?)
          _materializePlan(defaultValue, prepared),
      ];
      return <String, dynamic>{
        'var': rawParameters is List
            ? materializedParameters
            : materializedParameters.first,
      };
    }
    if (plan is JsonLogicOperatorPlan) {
      final materializedParameters = <dynamic>[
        for (final parameter in plan.parameters)
          _materializePlan(parameter, prepared),
      ];
      final rawParameters = plan.rawRule[plan.operatorName];
      return <String, dynamic>{
        plan.operatorName: rawParameters is List
            ? materializedParameters
            : materializedParameters.isEmpty
            ? rawParameters
            : materializedParameters.first,
      };
    }
    if (plan is JsonLogicMultiAndPlan) {
      final result = <String, dynamic>{};
      for (final entry in plan.entries) {
        final materialized = _materializePlan(entry, prepared);
        if (materialized is Map<String, dynamic>) {
          result.addAll(materialized);
        }
      }
      return result;
    }
    if (plan is JsonLogicFallbackPlan) {
      return _preparedValue(plan, prepared);
    }
    return null;
  }

  dynamic _preparedValue(
    JsonLogicExpressionPlan plan,
    CompiledJsonLogicPreparedValues? prepared,
  ) {
    if (prepared == null || !prepared.containsKey(plan)) {
      throw StateError(
        'Compiled JSONLogic plan was evaluated without its prepared values '
        '(${plan.sourcePath}).',
      );
    }
    return prepared[plan];
  }

  dynamic _evaluateOperator(
    JsonLogicOperatorPlan plan,
    dynamic data,
    CompiledJsonLogicPreparedValues? prepared,
  ) {
    final parameters = plan.parameters;
    dynamic evaluateAt(int index) =>
        _evaluatePlan(parameters[index], data, prepared);

    switch (plan.operatorName) {
      case 'if':
      case '?:':
        var index = 0;
        while (true) {
          if (index >= parameters.length) return null;
          if (index == parameters.length - 1) return evaluateAt(index);
          if (_truth(evaluateAt(index))) return evaluateAt(index + 1);
          index += 2;
        }
      case 'and':
        dynamic value;
        for (var index = 0; index < parameters.length; index++) {
          value = evaluateAt(index);
          if (!_truth(value)) return value;
        }
        return value;
      case 'or':
        dynamic value;
        for (var index = 0; index < parameters.length; index++) {
          value = evaluateAt(index);
          if (_truth(value)) return value;
        }
        return value;
      case '!':
        return parameters.isEmpty ? false : !_truth(evaluateAt(0));
      case '!!':
        return parameters.isEmpty ? false : _truth(evaluateAt(0));
      case '==':
        return _looseEqual(parameters, evaluateAt);
      case '!=':
        return !_looseEqual(parameters, evaluateAt);
      case '===':
        if (parameters.isEmpty) return false;
        if (parameters.length == 1) return evaluateAt(0) == null;
        return evaluateAt(0) == evaluateAt(1);
      case '!==':
        if (parameters.isEmpty) return false;
        if (parameters.length == 1) return evaluateAt(0) != null;
        return evaluateAt(0) != evaluateAt(1);
      case '+':
        return _reduceNumbers(
          parameters,
          evaluateAt,
          0.0,
          (left, right) => left + right,
        );
      case '*':
        return _reduceNumbers(
          parameters,
          evaluateAt,
          1.0,
          (left, right) => left * right,
        );
      case '-':
        if (parameters.length == 1) {
          final value = _number(evaluateAt(0));
          return value == null ? null : -value;
        }
        return _binaryNumber(parameters, evaluateAt, (left, right) {
          return left - right;
        });
      case '/':
        return _binaryNumber(parameters, evaluateAt, (left, right) {
          return left / right;
        });
      case '%':
        return _binaryNumber(parameters, evaluateAt, (left, right) {
          return left % right;
        });
      case '>':
        return _compareNumbers(
          parameters,
          evaluateAt,
          double.infinity,
          (left, right) => left > right,
        );
      case '>=':
        return _compareNumbers(
          parameters,
          evaluateAt,
          double.infinity,
          (left, right) => left >= right,
        );
      case '<':
        return _compareNumbers(
          parameters,
          evaluateAt,
          -double.infinity,
          (left, right) => left < right,
        );
      case '<=':
        return _compareNumbers(
          parameters,
          evaluateAt,
          -double.infinity,
          (left, right) => left <= right,
        );
      case 'min':
        return _reduceNumbers(
          parameters,
          evaluateAt,
          double.infinity,
          (left, right) => left < right ? left : right,
        );
      case 'max':
        return _reduceNumbers(
          parameters,
          evaluateAt,
          -double.infinity,
          (left, right) => left > right ? left : right,
        );
      case 'var':
        if (parameters.isEmpty) return data;
        final key = evaluateAt(0);
        final found = _findVariable(key, data);
        if (!found.$2) return found.$1;
        return parameters.length >= 2 ? evaluateAt(1) : null;
      case 'missing':
        return _evaluateMissing(parameters, data, prepared);
      case 'missing_some':
        return _evaluateMissingSome(parameters, data, prepared);
      case 'cat':
        return <String>[
          for (var index = 0; index < parameters.length; index++)
            _string(evaluateAt(index)),
        ].join();
      case 'substr':
        return _evaluateSubstr(parameters, evaluateAt);
      case 'in':
        if (parameters.length != 2) return false;
        final needle = evaluateAt(0);
        final haystack = evaluateAt(1);
        if (needle is String && haystack is String) {
          return haystack.contains(needle);
        }
        if (needle is String && haystack is List) {
          return haystack.contains(needle);
        }
        return false;
      case 'merge':
        final result = <dynamic>[];
        for (var index = 0; index < parameters.length; index++) {
          final value = evaluateAt(index);
          if (value is List) {
            result.addAll(value);
          } else {
            result.add(value);
          }
        }
        return result;
      case 'map':
      case 'filter':
      case 'reduce':
      case 'all':
      case 'some':
      case 'none':
      case 'log':
      case 'method':
        return _evaluateFallbackOperator(plan, data, prepared);
      default:
        final customResult = customOperatorEvaluator?.call(
          plan.operatorName,
          parameters.length,
          evaluateAt,
        );
        if (customResult != null && customResult.handled) {
          return customResult.value;
        }
        // Unknown custom operations remain owned by the Jsonlogic runtime.
        return _evaluateFallbackOperator(plan, data, prepared);
    }
  }

  dynamic _evaluateFallbackOperator(
    JsonLogicOperatorPlan plan,
    dynamic data,
    CompiledJsonLogicPreparedValues? prepared,
  ) {
    return fallbackRuntime.apply(_materializePlan(plan, prepared), data);
  }

  bool _looseEqual(
    List<JsonLogicExpressionPlan> parameters,
    dynamic Function(int index) evaluateAt,
  ) {
    if (parameters.isEmpty) return false;
    if (parameters.length == 1) return evaluateAt(0) == null;
    final left = evaluateAt(0);
    final right = evaluateAt(1);
    if (left is String || right is String) {
      return _string(left) == _string(right);
    }
    if (left is bool || right is bool) {
      return _truth(left) == _truth(right);
    }
    return left == right;
  }

  num? _binaryNumber(
    List<JsonLogicExpressionPlan> parameters,
    dynamic Function(int index) evaluateAt,
    num Function(num left, num right) operation,
  ) {
    if (parameters.length <= 1) return null;
    final left = _number(evaluateAt(0));
    final right = _number(evaluateAt(1));
    if (left == null || right == null) return null;
    return operation(left, right);
  }

  num? _reduceNumbers(
    List<JsonLogicExpressionPlan> parameters,
    dynamic Function(int index) evaluateAt,
    num initialValue,
    num Function(num left, num right) operation,
  ) {
    var result = initialValue;
    for (var index = 0; index < parameters.length; index++) {
      final value = _number(evaluateAt(index));
      if (value == null) return null;
      result = operation(result, value);
      if (result.isNaN) break;
    }
    return result;
  }

  bool _compareNumbers(
    List<JsonLogicExpressionPlan> parameters,
    dynamic Function(int index) evaluateAt,
    num initialValue,
    bool Function(num left, num right) compare,
  ) {
    var result = initialValue;
    for (var index = 0; index < parameters.length; index++) {
      final value = _number(evaluateAt(index));
      if (value == null) return false;
      result = compare(result, value) ? value : double.nan;
      if (result.isNaN) break;
    }
    return !result.isNaN;
  }

  List<dynamic> _evaluateMissing(
    List<JsonLogicExpressionPlan> parameters,
    dynamic data,
    CompiledJsonLogicPreparedValues? prepared,
  ) {
    if (parameters.length == 1) {
      final value = _evaluatePlan(parameters.first, data, prepared);
      if (value is! List) {
        return _findVariable(value, data).$2 ? <dynamic>[value] : <dynamic>[];
      }
      final missing = <dynamic>[];
      for (final candidateRule in value) {
        final key = fallbackRuntime.apply(candidateRule, data);
        if (_findVariable(key, data).$2) missing.add(key);
      }
      return missing;
    }

    final missing = <dynamic>[];
    for (final parameter in parameters) {
      final key = _evaluatePlan(parameter, data, prepared);
      if (_findVariable(key, data).$2) missing.add(key);
    }
    return missing;
  }

  List<dynamic> _evaluateMissingSome(
    List<JsonLogicExpressionPlan> parameters,
    dynamic data,
    CompiledJsonLogicPreparedValues? prepared,
  ) {
    if (parameters.length != 2) return <dynamic>[];
    final count = _evaluatePlan(parameters[0], data, prepared);
    final candidates = _evaluatePlan(parameters[1], data, prepared);
    if (count is! num || candidates is! List) return <dynamic>[];
    final minimumRequired = count.toInt();
    if (minimumRequired < 1) return <dynamic>[];

    final missing = <dynamic>[];
    var foundCount = 0;
    for (final candidateRule in candidates) {
      final key = fallbackRuntime.apply(candidateRule, data);
      if (_findVariable(key, data).$2) {
        missing.add(key);
      } else {
        foundCount++;
        if (foundCount >= minimumRequired) return <dynamic>[];
      }
    }
    return missing;
  }

  dynamic _evaluateSubstr(
    List<JsonLogicExpressionPlan> parameters,
    dynamic Function(int index) evaluateAt,
  ) {
    if (parameters.isEmpty) return '';
    final source = evaluateAt(0);
    if (source is! String) return '';

    var start = 0;
    if (parameters.length > 1) {
      final rawStart = evaluateAt(1);
      if (rawStart is! int) return source;
      start = rawStart;
      if (start < 0) start += source.length;
      if (start < 0 || start > source.length) return '';
    }

    if (parameters.length > 2) {
      final rawLength = evaluateAt(2);
      if (rawLength is int) {
        var length = rawLength;
        if (length < 0) length += source.length - start;
        if (length < 0 || start + length > source.length) {
          length = source.length - start;
        }
        return source.substring(start, start + length);
      }
      // jsonlogic 2.0.2 falls through without a value in this case.
      return null;
    }
    return source.substring(start);
  }

  (dynamic, bool) _findVariable(
    dynamic key,
    dynamic data, {
    List<String>? segments,
  }) {
    var notFound = false;
    final List<String> keys;
    if (segments != null) {
      keys = segments;
    } else if (key is String) {
      if (key.isEmpty) return (data, false);
      keys = key.split('.');
    } else if (key is num) {
      keys = <String>['$key'];
    } else if (key == null) {
      return (data, false);
    } else {
      keys = const <String>[];
      notFound = true;
    }

    var current = data;
    for (final segment in keys) {
      if (notFound) break;
      if (current is Map) {
        final value = current[segment];
        if (value == null) {
          notFound = true;
        } else {
          current = value;
        }
      } else if (current is List) {
        final index = int.tryParse(segment);
        if (index == null || index < 0 || index >= current.length) {
          notFound = true;
        } else {
          current = current[index];
        }
      } else {
        notFound = true;
      }
    }
    return (current, notFound);
  }

  static num? _number(dynamic value) {
    if (value is num) return value;
    if (value is String) return double.tryParse(value);
    return null;
  }

  static bool _truth(dynamic value) {
    if (value == null) return false;
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) return value.isNotEmpty;
    if (value is List || value is Map) return value.isNotEmpty;
    return true;
  }

  static String _string(dynamic value) {
    if (value == null) return '';
    if (value is String) return value;
    if (value is List || value is Map) return jsonEncode(value);
    return '$value';
  }
}
