// JsonLogic 表达式引擎 v2.0
// 支持完整的算术、比较、逻辑、字符串、数组运算
// 所有 { "op": [...] } 形式的 JSON 节点都通过此引擎求值

class ExpressionEngine {
  /// 外部提供的变量解析器
  final dynamic Function(String path) variableResolver;

  /// 外部提供的模板解析器（处理 {{ $.xxx }} 插值）
  final String Function(String template)? templateResolver;

  /// filter/map 迭代变量栈（{ "var": "" } 使用此栈）
  final List<dynamic> _iteratorStack = [];

  ExpressionEngine({
    required this.variableResolver,
    this.templateResolver,
  });

  /// 求值入口
  dynamic evaluate(dynamic expr) {
    if (expr == null) return null;

    // 原始值直接返回
    if (expr is num || expr is bool) return expr;

    // 字符串：如果包含 {{ }} 模板，先解析
    if (expr is String) {
      if (templateResolver != null && expr.contains('{{') && expr.contains('}}')) {
        return templateResolver!(expr);
      }
      return expr;
    }

    // 数组：递归求值每个元素
    if (expr is List) {
      return expr.map((e) => evaluate(e)).toList();
    }

    // Map：JsonLogic 操作节点
    if (expr is Map<String, dynamic>) {
      return _evaluateOp(expr);
    }

    return expr;
  }

  /// 求值布尔条件
  bool evaluateBool(dynamic expr) {
    final result = evaluate(expr);
    return _toBool(result);
  }

  /// 推入迭代变量（供 filter/map 使用）
  void pushIterator(dynamic item) => _iteratorStack.add(item);

  /// 弹出迭代变量
  void popIterator() {
    if (_iteratorStack.isNotEmpty) _iteratorStack.removeLast();
  }

  // ---------- 核心分发 ----------

  dynamic _evaluateOp(Map<String, dynamic> node) {
    // 单操作符 Map: { "op": args }
    if (node.length == 1) {
      final op = node.keys.first;
      final args = node.values.first;
      return _dispatch(op, args);
    }

    // 多键 Map：可能是 { "var": "...", "default": ... } 等
    if (node.containsKey('var')) {
      return _opVar(node['var'], node['default']);
    }

    // 非操作节点，原样返回
    return node;
  }

  dynamic _dispatch(String op, dynamic rawArgs) {
    switch (op) {
      // ---- 数据访问 ----
      case 'var':
        return _opVar(rawArgs, null);

      // ---- 算术 ----
      case '+':
        return _opArithmetic(rawArgs, (a, b) => a + b);
      case '-':
        return _opArithmetic(rawArgs, (a, b) => a - b);
      case '*':
        return _opArithmetic(rawArgs, (a, b) => a * b);
      case '/':
        return _opArithmetic(rawArgs, (a, b) => b != 0 ? a / b : 0);
      case '%':
        return _opArithmetic(rawArgs, (a, b) => b != 0 ? a % b : 0);

      // ---- 比较 ----
      case '==':
        return _opCompare(rawArgs, (a, b) => a == b);
      case '!=':
        return _opCompare(rawArgs, (a, b) => a != b);
      case '>':
        return _opNumCompare(rawArgs, (a, b) => a > b);
      case '<':
        return _opNumCompare(rawArgs, (a, b) => a < b);
      case '>=':
        return _opNumCompare(rawArgs, (a, b) => a >= b);
      case '<=':
        return _opNumCompare(rawArgs, (a, b) => a <= b);

      // ---- 逻辑 ----
      case 'and':
        return _opAnd(rawArgs);
      case 'or':
        return _opOr(rawArgs);
      case '!':
      case 'not':
        return _opNot(rawArgs);
      case 'if':
      case '?:':
        return _opIf(rawArgs);
      case '!!':
        return _toBool(evaluate(_asList(rawArgs).firstOrNull));

      // ---- 字符串 ----
      case 'cat':
        return _opCat(rawArgs);
      case 'substr':
        return _opSubstr(rawArgs);
      case 'str_len':
        return _opStrLen(rawArgs);
      case 'str_upper':
        return _opStrUpper(rawArgs);
      case 'str_lower':
        return _opStrLower(rawArgs);
      case 'str_trim':
        return _opStrTrim(rawArgs);
      case 'str_contains':
        return _opStrContains(rawArgs);
      case 'str_replace':
        return _opStrReplace(rawArgs);
      case 'str_split':
        return _opStrSplit(rawArgs);
      case 'str_join':
        return _opStrJoin(rawArgs);

      // ---- 数组 ----
      case 'merge':
        return _opMerge(rawArgs);
      case 'in':
        return _opIn(rawArgs);
      case 'filter':
        return _opFilter(rawArgs);
      case 'map':
        return _opMap(rawArgs);
      case 'reduce':
        return _opReduce(rawArgs);
      case 'all':
        return _opAll(rawArgs);
      case 'some':
        return _opSome(rawArgs);
      case 'none':
        return _opNone(rawArgs);
      case 'length':
        return _opLength(rawArgs);
      case 'at':
        return _opAt(rawArgs);
      case 'slice':
        return _opSlice(rawArgs);
      case 'sort':
        return _opSort(rawArgs);
      case 'reverse':
        return _opReverse(rawArgs);

      // ---- 类型转换 ----
      case 'to_string':
        return evaluate(_asList(rawArgs).firstOrNull)?.toString() ?? '';
      case 'to_int':
        return _toNum(evaluate(_asList(rawArgs).firstOrNull))?.toInt() ?? 0;
      case 'to_double':
        return _toNum(evaluate(_asList(rawArgs).firstOrNull))?.toDouble() ?? 0.0;

      // ---- 数学 ----
      case 'min':
        return _opMin(rawArgs);
      case 'max':
        return _opMax(rawArgs);
      case 'abs':
        final v = _toNum(evaluate(_asList(rawArgs).firstOrNull));
        return v != null ? (v < 0 ? -v : v) : 0;

      default:
        return node(op, rawArgs);
    }
  }

  // ignore: avoid-dynamic
  dynamic node(String op, dynamic rawArgs) => {op: rawArgs};

  // ========== 数据访问 ==========

  dynamic _opVar(dynamic path, dynamic defaultValue) {
    if (path is! String) return defaultValue;
    if (path.isEmpty) {
      // { "var": "" } → 当前迭代元素
      if (_iteratorStack.isNotEmpty) return _iteratorStack.last;
      return defaultValue;
    }
    final result = variableResolver(path);
    return result ?? (defaultValue != null ? evaluate(defaultValue) : null);
  }

  // ========== 算术 ==========

  dynamic _opArithmetic(dynamic rawArgs, num Function(num, num) op) {
    final args = _asList(rawArgs);
    if (args.isEmpty) return 0;
    if (args.length == 1) {
      return _toNum(evaluate(args[0])) ?? 0;
    }
    num result = _toNum(evaluate(args[0])) ?? 0;
    for (var i = 1; i < args.length; i++) {
      final val = _toNum(evaluate(args[i])) ?? 0;
      result = op(result, val);
    }
    // 如果结果是整数，返回 int
    if (result == result.toInt()) return result.toInt();
    return result;
  }

  // ========== 比较 ==========

  bool _opCompare(dynamic rawArgs, bool Function(dynamic, dynamic) op) {
    final args = _asList(rawArgs);
    if (args.length < 2) return false;
    final left = evaluate(args[0]);
    final right = evaluate(args[1]);
    return op(left, right);
  }

  bool _opNumCompare(dynamic rawArgs, bool Function(num, num) op) {
    final args = _asList(rawArgs);
    if (args.length < 2) return false;
    final left = _toNum(evaluate(args[0]));
    final right = _toNum(evaluate(args[1]));
    if (left == null || right == null) return false;
    return op(left, right);
  }

  // ========== 逻辑 ==========

  dynamic _opAnd(dynamic rawArgs) {
    final args = _asList(rawArgs);
    dynamic last = false;
    for (final arg in args) {
      last = evaluate(arg);
      if (!_toBool(last)) return last;
    }
    return last;
  }

  dynamic _opOr(dynamic rawArgs) {
    final args = _asList(rawArgs);
    dynamic last = false;
    for (final arg in args) {
      last = evaluate(arg);
      if (_toBool(last)) return last;
    }
    return last;
  }

  bool _opNot(dynamic rawArgs) {
    final args = _asList(rawArgs);
    if (args.isEmpty) return true;
    return !_toBool(evaluate(args[0]));
  }

  dynamic _opIf(dynamic rawArgs) {
    final args = _asList(rawArgs);
    // if(cond, then, else) or if(c1, t1, c2, t2, ..., elseVal)
    for (var i = 0; i < args.length - 1; i += 2) {
      if (_toBool(evaluate(args[i]))) {
        return evaluate(args[i + 1]);
      }
    }
    // 奇数个参数 → 最后一个是 else 值
    if (args.length.isOdd) {
      return evaluate(args.last);
    }
    return null;
  }

  // ========== 字符串 ==========

  dynamic _opCat(dynamic rawArgs) {
    final args = _asList(rawArgs);
    // 如果所有参数都是列表或可解析为列表，做数组拼接
    // 否则做字符串拼接
    final evaluated = args.map((e) => evaluate(e)).toList();
    final allLists = evaluated.every((e) => e is List);
    if (allLists && evaluated.isNotEmpty) {
      // 数组合并
      final result = <dynamic>[];
      for (final e in evaluated) {
        result.addAll(e as List);
      }
      return result;
    }
    // 字符串拼接
    return evaluated.map((e) => e?.toString() ?? '').join();
  }

  String _opSubstr(dynamic rawArgs) {
    final args = _asList(rawArgs);
    if (args.isEmpty) return '';
    final str = evaluate(args[0])?.toString() ?? '';
    final start = _toNum(evaluate(args.length > 1 ? args[1] : 0))?.toInt() ?? 0;
    final len = args.length > 2 ? _toNum(evaluate(args[2]))?.toInt() : null;

    final actualStart = start < 0 ? (str.length + start).clamp(0, str.length) : start.clamp(0, str.length);
    if (len == null) return str.substring(actualStart);
    if (len < 0) return str.substring(actualStart, (str.length + len).clamp(actualStart, str.length));
    return str.substring(actualStart, (actualStart + len).clamp(actualStart, str.length));
  }

  int _opStrLen(dynamic rawArgs) {
    final args = _asList(rawArgs);
    final str = evaluate(args.firstOrNull)?.toString() ?? '';
    return str.length;
  }

  String _opStrUpper(dynamic rawArgs) {
    final args = _asList(rawArgs);
    return (evaluate(args.firstOrNull)?.toString() ?? '').toUpperCase();
  }

  String _opStrLower(dynamic rawArgs) {
    final args = _asList(rawArgs);
    return (evaluate(args.firstOrNull)?.toString() ?? '').toLowerCase();
  }

  String _opStrTrim(dynamic rawArgs) {
    final args = _asList(rawArgs);
    return (evaluate(args.firstOrNull)?.toString() ?? '').trim();
  }

  bool _opStrContains(dynamic rawArgs) {
    final args = _asList(rawArgs);
    if (args.length < 2) return false;
    final str = evaluate(args[0])?.toString() ?? '';
    final search = evaluate(args[1])?.toString() ?? '';
    return str.contains(search);
  }

  String _opStrReplace(dynamic rawArgs) {
    final args = _asList(rawArgs);
    if (args.length < 3) return evaluate(args.firstOrNull)?.toString() ?? '';
    final str = evaluate(args[0])?.toString() ?? '';
    final from = evaluate(args[1])?.toString() ?? '';
    final to = evaluate(args[2])?.toString() ?? '';
    return str.replaceAll(from, to);
  }

  List<String> _opStrSplit(dynamic rawArgs) {
    final args = _asList(rawArgs);
    if (args.length < 2) return [evaluate(args.firstOrNull)?.toString() ?? ''];
    final str = evaluate(args[0])?.toString() ?? '';
    final sep = evaluate(args[1])?.toString() ?? '';
    return str.split(sep);
  }

  String _opStrJoin(dynamic rawArgs) {
    final args = _asList(rawArgs);
    if (args.isEmpty) return '';
    final list = evaluate(args[0]);
    final sep = args.length > 1 ? evaluate(args[1])?.toString() ?? '' : '';
    if (list is List) {
      return list.map((e) => e?.toString() ?? '').join(sep);
    }
    return list?.toString() ?? '';
  }

  // ========== 数组 ==========

  List<dynamic> _opMerge(dynamic rawArgs) {
    final args = _asList(rawArgs);
    final result = <dynamic>[];
    for (final arg in args) {
      final val = evaluate(arg);
      if (val is List) {
        result.addAll(val);
      } else {
        result.add(val);
      }
    }
    return result;
  }

  bool _opIn(dynamic rawArgs) {
    final args = _asList(rawArgs);
    if (args.length < 2) return false;
    final needle = evaluate(args[0]);
    final haystack = evaluate(args[1]);
    if (haystack is List) return haystack.contains(needle);
    if (haystack is String && needle is String) return haystack.contains(needle);
    return false;
  }

  List<dynamic> _opFilter(dynamic rawArgs) {
    final args = _asList(rawArgs);
    if (args.length < 2) return [];
    final source = evaluate(args[0]);
    if (source is! List) return [];
    final condition = args[1];
    return source.where((item) {
      _iteratorStack.add(item);
      final result = _toBool(evaluate(condition));
      _iteratorStack.removeLast();
      return result;
    }).toList();
  }

  List<dynamic> _opMap(dynamic rawArgs) {
    final args = _asList(rawArgs);
    if (args.length < 2) return [];
    final source = evaluate(args[0]);
    if (source is! List) return [];
    final transform = args[1];
    return source.map((item) {
      _iteratorStack.add(item);
      final result = evaluate(transform);
      _iteratorStack.removeLast();
      return result;
    }).toList();
  }

  dynamic _opReduce(dynamic rawArgs) {
    final args = _asList(rawArgs);
    if (args.length < 3) return null;
    final source = evaluate(args[0]);
    if (source is! List) return null;
    final reducer = args[1];
    dynamic accumulator = evaluate(args[2]);
    for (final item in source) {
      _iteratorStack.add({'current': item, 'accumulator': accumulator});
      accumulator = evaluate(reducer);
      _iteratorStack.removeLast();
    }
    return accumulator;
  }

  bool _opAll(dynamic rawArgs) {
    final args = _asList(rawArgs);
    if (args.length < 2) return false;
    final source = evaluate(args[0]);
    if (source is! List || source.isEmpty) return false;
    final condition = args[1];
    return source.every((item) {
      _iteratorStack.add(item);
      final result = _toBool(evaluate(condition));
      _iteratorStack.removeLast();
      return result;
    });
  }

  bool _opSome(dynamic rawArgs) {
    final args = _asList(rawArgs);
    if (args.length < 2) return false;
    final source = evaluate(args[0]);
    if (source is! List || source.isEmpty) return false;
    final condition = args[1];
    return source.any((item) {
      _iteratorStack.add(item);
      final result = _toBool(evaluate(condition));
      _iteratorStack.removeLast();
      return result;
    });
  }

  bool _opNone(dynamic rawArgs) {
    final args = _asList(rawArgs);
    if (args.length < 2) return true;
    final source = evaluate(args[0]);
    if (source is! List || source.isEmpty) return true;
    final condition = args[1];
    return !source.any((item) {
      _iteratorStack.add(item);
      final result = _toBool(evaluate(condition));
      _iteratorStack.removeLast();
      return result;
    });
  }

  int _opLength(dynamic rawArgs) {
    final args = _asList(rawArgs);
    final val = evaluate(args.firstOrNull);
    if (val is List) return val.length;
    if (val is String) return val.length;
    if (val is Map) return val.length;
    return 0;
  }

  dynamic _opAt(dynamic rawArgs) {
    final args = _asList(rawArgs);
    if (args.length < 2) return null;
    final source = evaluate(args[0]);
    final index = _toNum(evaluate(args[1]))?.toInt();
    if (index == null) return null;
    if (source is List && index >= 0 && index < source.length) {
      return source[index];
    }
    if (source is String && index >= 0 && index < source.length) {
      return source[index];
    }
    return null;
  }

  List<dynamic> _opSlice(dynamic rawArgs) {
    final args = _asList(rawArgs);
    if (args.isEmpty) return [];
    final source = evaluate(args[0]);
    if (source is! List) return [];
    final start = _toNum(evaluate(args.length > 1 ? args[1] : 0))?.toInt() ?? 0;
    final end = args.length > 2 ? _toNum(evaluate(args[2]))?.toInt() : null;
    final actualStart = start.clamp(0, source.length);
    final actualEnd = (end ?? source.length).clamp(actualStart, source.length);
    return source.sublist(actualStart, actualEnd);
  }

  List<dynamic> _opSort(dynamic rawArgs) {
    final args = _asList(rawArgs);
    if (args.isEmpty) return [];
    final source = evaluate(args[0]);
    if (source is! List) return [];
    final copy = List<dynamic>.from(source);
    copy.sort((a, b) {
      if (a is num && b is num) return a.compareTo(b);
      return a.toString().compareTo(b.toString());
    });
    return copy;
  }

  List<dynamic> _opReverse(dynamic rawArgs) {
    final args = _asList(rawArgs);
    if (args.isEmpty) return [];
    final source = evaluate(args[0]);
    if (source is! List) return [];
    return source.reversed.toList();
  }

  // ========== 数学 ==========

  num _opMin(dynamic rawArgs) {
    final args = _asList(rawArgs);
    final values = args.map((e) => _toNum(evaluate(e))).whereType<num>();
    if (values.isEmpty) return 0;
    return values.reduce((a, b) => a < b ? a : b);
  }

  num _opMax(dynamic rawArgs) {
    final args = _asList(rawArgs);
    final values = args.map((e) => _toNum(evaluate(e))).whereType<num>();
    if (values.isEmpty) return 0;
    return values.reduce((a, b) => a > b ? a : b);
  }

  // ========== 工具方法 ==========

  List<dynamic> _asList(dynamic val) {
    if (val is List) return val;
    return [val];
  }

  bool _toBool(dynamic val) {
    if (val == null) return false;
    if (val is bool) return val;
    if (val is num) return val != 0;
    if (val is String) return val.isNotEmpty;
    if (val is List) return val.isNotEmpty;
    return true;
  }

  num? _toNum(dynamic val) {
    if (val is num) return val;
    if (val is String) return num.tryParse(val);
    if (val is bool) return val ? 1 : 0;
    return null;
  }
}
