import 'template_plan.dart';

sealed class JsonLogicExpressionPlan {
  const JsonLogicExpressionPlan({
    required this.sourcePath,
    required this.globalDependencies,
  });

  final String sourcePath;
  final Set<String> globalDependencies;
}

final class JsonLogicConstantPlan extends JsonLogicExpressionPlan {
  const JsonLogicConstantPlan({required this.value, required super.sourcePath})
    : super(globalDependencies: const <String>{});

  final dynamic value;
}

/// Template leaf materialized before JSONLogic evaluation.
///
/// JSONLogic preprocessing uses string template semantics even when the leaf
/// consists of one exact binding.
final class JsonLogicTemplatePlan extends JsonLogicExpressionPlan {
  JsonLogicTemplatePlan({required this.template, required super.sourcePath})
    : super(globalDependencies: template.globalDependencies);

  final TemplatePlan template;
}

/// A List used as one JSONLogic rule is literal data, not a list of rules.
final class JsonLogicLiteralListPlan extends JsonLogicExpressionPlan {
  JsonLogicLiteralListPlan({required this.items, required super.sourcePath})
    : super(
        globalDependencies: Set<String>.unmodifiable(
          items.expand((item) => item.globalDependencies),
        ),
      );

  final List<JsonLogicExpressionPlan> items;
}

/// A Map nested inside literal List data is materialized but not dispatched.
final class JsonLogicLiteralMapPlan extends JsonLogicExpressionPlan {
  JsonLogicLiteralMapPlan({required this.values, required super.sourcePath})
    : super(
        globalDependencies: Set<String>.unmodifiable(
          values.values.expand((value) => value.globalDependencies),
        ),
      );

  final Map<String, JsonLogicExpressionPlan> values;
}

final class JsonLogicOperatorPlan extends JsonLogicExpressionPlan {
  JsonLogicOperatorPlan({
    required this.operatorName,
    required this.parameters,
    required this.rawRule,
    required super.sourcePath,
  }) : super(
         globalDependencies: Set<String>.unmodifiable(
           parameters.expand((parameter) => parameter.globalDependencies),
         ),
       );

  final String operatorName;
  final List<JsonLogicExpressionPlan> parameters;
  final Map<String, dynamic> rawRule;
}

/// Specialized static `var` node with a path split once at App load.
final class JsonLogicVariablePlan extends JsonLogicExpressionPlan {
  JsonLogicVariablePlan({
    required this.key,
    required this.segments,
    required this.defaultValue,
    required this.rawRule,
    required super.sourcePath,
  }) : super(
         globalDependencies: Set<String>.unmodifiable(<String>{
           if (key is String && key.startsWith('global.')) key,
           ...?defaultValue?.globalDependencies,
         }),
       );

  final dynamic key;
  final List<String>? segments;
  final JsonLogicExpressionPlan? defaultValue;
  final Map<String, dynamic> rawRule;
}

/// JSONLogic's default aggregator for a Map containing more than one key.
final class JsonLogicMultiAndPlan extends JsonLogicExpressionPlan {
  JsonLogicMultiAndPlan({
    required this.entries,
    required this.rawRule,
    required super.sourcePath,
  }) : super(
         globalDependencies: Set<String>.unmodifiable(
           entries.expand((entry) => entry.globalDependencies),
         ),
       );

  final List<JsonLogicExpressionPlan> entries;
  final Map<String, dynamic> rawRule;
}

final class JsonLogicFallbackPlan extends JsonLogicExpressionPlan {
  const JsonLogicFallbackPlan({
    required this.rawRule,
    required super.sourcePath,
  }) : super(globalDependencies: const <String>{});

  final dynamic rawRule;
}

final class JsonLogicPlanCompiler {
  JsonLogicPlanCompiler({
    required this.knownOperators,
    required this.templateFor,
  });

  final Set<String> knownOperators;
  final TemplatePlan Function(String source) templateFor;

  JsonLogicExpressionPlan compile(dynamic rule, String sourcePath) {
    if (rule is String) {
      if (rule.contains('{{') && rule.contains('}}')) {
        return JsonLogicTemplatePlan(
          template: templateFor(rule),
          sourcePath: sourcePath,
        );
      }
      return JsonLogicConstantPlan(value: rule, sourcePath: sourcePath);
    }
    if (rule == null || rule is bool || rule is num) {
      return JsonLogicConstantPlan(value: rule, sourcePath: sourcePath);
    }
    if (rule is List<dynamic>) {
      return _compileLiteralList(rule, sourcePath);
    }
    if (rule is! Map<String, dynamic>) {
      return JsonLogicConstantPlan(value: rule, sourcePath: sourcePath);
    }

    if (rule.length > 1) {
      final entries = <JsonLogicExpressionPlan>[];
      for (final entry in rule.entries) {
        entries.add(
          compile(<String, dynamic>{
            entry.key: entry.value,
          }, '$sourcePath.${entry.key}'),
        );
      }
      return JsonLogicMultiAndPlan(
        entries: List<JsonLogicExpressionPlan>.unmodifiable(entries),
        rawRule: rule,
        sourcePath: sourcePath,
      );
    }
    if (rule.isEmpty) {
      return JsonLogicFallbackPlan(rawRule: rule, sourcePath: sourcePath);
    }

    final operatorName = rule.keys.first;
    if (!knownOperators.contains(operatorName)) {
      return JsonLogicFallbackPlan(rawRule: rule, sourcePath: sourcePath);
    }
    final rawParameters = rule.values.first;
    final parameterSources = rawParameters is List
        ? rawParameters
        : <dynamic>[rawParameters];
    if (operatorName == 'var' && parameterSources.isNotEmpty) {
      final key = parameterSources.first;
      if ((key == null || key is num || key is String) &&
          (key is! String || (!key.contains('{{') && !key.contains('}}')))) {
        final normalizedKey = key is num ? '$key' : key;
        return JsonLogicVariablePlan(
          key: normalizedKey,
          segments: normalizedKey is String && normalizedKey.isNotEmpty
              ? List<String>.unmodifiable(normalizedKey.split('.'))
              : null,
          defaultValue: parameterSources.length > 1
              ? compile(parameterSources[1], '$sourcePath.var.default')
              : null,
          rawRule: rule,
          sourcePath: sourcePath,
        );
      }
    }

    final parameters = <JsonLogicExpressionPlan>[
      for (var index = 0; index < parameterSources.length; index++)
        compile(parameterSources[index], '$sourcePath.$operatorName[$index]'),
    ];
    return JsonLogicOperatorPlan(
      operatorName: operatorName,
      parameters: List<JsonLogicExpressionPlan>.unmodifiable(parameters),
      rawRule: rule,
      sourcePath: sourcePath,
    );
  }

  JsonLogicExpressionPlan _compileLiteral(dynamic value, String sourcePath) {
    if (value is String && value.contains('{{') && value.contains('}}')) {
      return JsonLogicTemplatePlan(
        template: templateFor(value),
        sourcePath: sourcePath,
      );
    }
    if (value is List<dynamic>) {
      return _compileLiteralList(value, sourcePath);
    }
    if (value is Map<String, dynamic>) {
      final values = <String, JsonLogicExpressionPlan>{};
      for (final entry in value.entries) {
        values[entry.key] = _compileLiteral(
          entry.value,
          '$sourcePath.${entry.key}',
        );
      }
      return JsonLogicLiteralMapPlan(
        values: Map<String, JsonLogicExpressionPlan>.unmodifiable(values),
        sourcePath: sourcePath,
      );
    }
    return JsonLogicConstantPlan(value: value, sourcePath: sourcePath);
  }

  JsonLogicLiteralListPlan _compileLiteralList(
    List<dynamic> values,
    String sourcePath,
  ) {
    return JsonLogicLiteralListPlan(
      items:
          List<JsonLogicExpressionPlan>.unmodifiable(<JsonLogicExpressionPlan>[
            for (var index = 0; index < values.length; index++)
              _compileLiteral(values[index], '$sourcePath[$index]'),
          ]),
      sourcePath: sourcePath,
    );
  }
}
