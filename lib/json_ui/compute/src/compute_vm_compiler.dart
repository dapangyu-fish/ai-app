part of '../compute_vm.dart';

final class _ComputeVmCompiler {
  _ComputeVmCompiler(
    this.specification, {
    required this.hosts,
    required this.limits,
  });

  final Map<String, dynamic> specification;
  final Map<String, ComputeVmHostFunction> hosts;
  final ComputeVmLimits limits;

  final List<int> _constants = <int>[];
  final Map<int, int> _constantIds = <int, int>{};
  final List<_VmCallSite> _callSites = <_VmCallSite>[];
  final List<_VmHostSite> _hostSites = <_VmHostSite>[];
  final List<_VmSwitchSite> _switchSites = <_VmSwitchSite>[];
  final List<_VmBulkSite> _bulkSites = <_VmBulkSite>[];
  var _astNodeCount = 0;

  ComputeVmProgram compile() {
    _validateLimits();
    final version = specification['version'];
    if (version is! num || !version.isFinite || version != 2) {
      _fail(
        'version is required and must have the numeric value 2',
        r'$.version',
      );
    }

    final u8 = _allocateU8Buffers();
    final i32 = _allocateI32Buffers();
    final totalBufferBytes =
        u8.values.fold<int>(0, (total, buffer) => total + buffer.length) +
        i32.values.fold<int>(
          0,
          (total, buffer) => total + buffer.length * Int32List.bytesPerElement,
        );
    if (totalBufferBytes > limits.maxBufferBytes) {
      _fail(
        'typed buffers exceed ${limits.maxBufferBytes} total bytes',
        r'$.buffers',
      );
    }
    if (u8.length + i32.length > limits.maxBuffers) {
      _fail('module exceeds ${limits.maxBuffers} typed buffers', r'$.buffers');
    }
    for (final name in u8.keys) {
      if (i32.containsKey(name)) {
        _fail(
          'u8 and i32 buffers must not share the name "$name"',
          r'$.i32.' + name,
        );
      }
    }
    _applyInitialValues(u8, i32);

    final signatures = _readFunctions();
    final functionByName = <String, int>{
      for (final signature in signatures) signature.name: signature.id,
    };
    final u8Ids = <String, int>{};
    var nextId = 0;
    for (final name in u8.keys) {
      u8Ids[name] = nextId++;
    }
    final i32Ids = <String, int>{};
    nextId = 0;
    for (final name in i32.keys) {
      i32Ids[name] = nextId++;
    }
    final hostNames = hosts.keys.toList(growable: false);
    final hostIds = <String, int>{
      for (var i = 0; i < hostNames.length; i++) hostNames[i]: i,
    };

    final functions = <_VmFunction>[];
    var totalInstructions = 0;
    var totalSwitchTableEntries = 0;
    for (final signature in signatures) {
      final functionCompiler = _VmFunctionCompiler(
        signature: signature,
        signatures: signatures,
        functionByName: functionByName,
        u8Ids: u8Ids,
        i32Ids: i32Ids,
        hostIds: hostIds,
        constants: _constants,
        constantIds: _constantIds,
        callSites: _callSites,
        hostSites: _hostSites,
        switchSites: _switchSites,
        bulkSites: _bulkSites,
        limits: limits,
        instructionLimit: limits.maxInstructions - totalInstructions,
        switchTableEntryLimit:
            limits.maxSwitchTableEntries - totalSwitchTableEntries,
      );
      final function = functionCompiler.compile();
      totalInstructions += function.instructionCount;
      totalSwitchTableEntries += functionCompiler.switchTableEntries;
      functions.add(function);
    }

    final module = _VmModule(
      functions: List<_VmFunction>.unmodifiable(functions),
      functionByName: Map<String, int>.unmodifiable(functionByName),
      constants: List<int>.unmodifiable(_constants),
      callSites: List<_VmCallSite>.unmodifiable(_callSites),
      hostSites: List<_VmHostSite>.unmodifiable(_hostSites),
      switchSites: List<_VmSwitchSite>.unmodifiable(_switchSites),
      bulkSites: List<_VmBulkSite>.unmodifiable(_bulkSites),
      hostNames: List<String>.unmodifiable(hostNames),
    );
    return ComputeVmProgram._(
      u8: u8,
      i32: i32,
      module: module,
      hosts: hosts,
      limits: limits,
    );
  }

  void _validateLimits() {
    final nonNegative = <String, int>{
      'maxFunctions': limits.maxFunctions,
      'maxBuffers': limits.maxBuffers,
      'maxInstructions': limits.maxInstructions,
      'maxConstants': limits.maxConstants,
      'maxCallSites': limits.maxCallSites,
      'maxHostSites': limits.maxHostSites,
      'maxSwitchSites': limits.maxSwitchSites,
      'maxBulkSites': limits.maxBulkSites,
      'maxRegistersPerFunction': limits.maxRegistersPerFunction,
      'maxU8Bytes': limits.maxU8Bytes,
      'maxI32Words': limits.maxI32Words,
      'maxBufferBytes': limits.maxBufferBytes,
      'maxInitializerElements': limits.maxInitializerElements,
      'maxAstNodes': limits.maxAstNodes,
      'maxSwitchTableEntries': limits.maxSwitchTableEntries,
      'maxStackWords': limits.maxStackWords,
    };
    for (final entry in nonNegative.entries) {
      if (entry.value < 0) {
        _fail('${entry.key} must not be negative', r'$.limits');
      }
    }
    final positive = <String, int>{
      'maxAstDepth': limits.maxAstDepth,
      'maxNameLength': limits.maxNameLength,
      'maxCallDepth': limits.maxCallDepth,
      'maxBudget': limits.maxBudget,
    };
    for (final entry in positive.entries) {
      if (entry.value <= 0) {
        _fail('${entry.key} must be positive', r'$.limits');
      }
    }
  }

  Map<String, Uint8List> _allocateU8Buffers() {
    final declarations = _mapAt('buffers', r'$.buffers', absent: true);
    if (declarations.length > limits.maxBuffers) {
      _fail('module exceeds ${limits.maxBuffers} typed buffers', r'$.buffers');
    }
    final result = <String, Uint8List>{};
    var total = 0;
    for (final entry in declarations.entries) {
      final size = _size(entry.value, '\$.buffers.${entry.key}');
      total += size;
      if (total > limits.maxU8Bytes) {
        _fail(
          'byte buffers exceed ${limits.maxU8Bytes} total bytes',
          r'$.buffers',
        );
      }
      result[entry.key] = Uint8List(size);
    }
    return result;
  }

  Map<String, Int32List> _allocateI32Buffers() {
    final declarations = _mapAt('i32', r'$.i32', absent: true);
    if (declarations.length > limits.maxBuffers) {
      _fail('module exceeds ${limits.maxBuffers} typed buffers', r'$.i32');
    }
    final result = <String, Int32List>{};
    var total = 0;
    for (final entry in declarations.entries) {
      final size = _size(entry.value, '\$.i32.${entry.key}');
      total += size;
      if (total > limits.maxI32Words) {
        _fail(
          'word buffers exceed ${limits.maxI32Words} total words',
          r'$.i32',
        );
      }
      result[entry.key] = Int32List(size);
    }
    return result;
  }

  void _applyInitialValues(
    Map<String, Uint8List> u8,
    Map<String, Int32List> i32,
  ) {
    final initializers = _mapAt('init', r'$.init', absent: true);
    var totalElements = 0;
    for (final entry in initializers.entries) {
      if (entry.value is! List) {
        _fail('initializer must be a list', '\$.init.${entry.key}');
      }
      final values = entry.value as List;
      totalElements += values.length;
      if (totalElements > limits.maxInitializerElements) {
        _fail(
          'initializers exceed ${limits.maxInitializerElements} total '
              'elements; use @compute.load for bulk byte data',
          r'$.init',
        );
      }
      final bytes = u8[entry.key];
      if (bytes != null) {
        if (values.length > bytes.length) {
          _fail(
            'initializer length ${values.length} exceeds buffer length '
                '${bytes.length}',
            '\$.init.${entry.key}',
          );
        }
        for (var i = 0; i < values.length; i++) {
          bytes[i] = _initializerInt(values[i], '\$.init.${entry.key}[$i]');
        }
        continue;
      }
      final words = i32[entry.key];
      if (words != null) {
        if (values.length > words.length) {
          _fail(
            'initializer length ${values.length} exceeds buffer length '
                '${words.length}',
            '\$.init.${entry.key}',
          );
        }
        for (var i = 0; i < values.length; i++) {
          words[i] = _initializerInt(values[i], '\$.init.${entry.key}[$i]');
        }
        continue;
      }
      _fail('initializer names an unknown buffer', '\$.init.${entry.key}');
    }
  }

  List<_FunctionSignature> _readFunctions() {
    final declarations = _mapAt('functions', r'$.functions');
    if (declarations.length > limits.maxFunctions) {
      _fail('module exceeds ${limits.maxFunctions} functions', r'$.functions');
    }
    final signatures = <_FunctionSignature>[];
    var id = 0;
    for (final entry in declarations.entries) {
      final path = r'$.functions.' + entry.key;
      if (entry.value is! Map) {
        _fail('function declaration must be an object', path);
      }
      final declaration = entry.value as Map;
      final paramsValue = declaration['params'] ?? const <dynamic>[];
      final bodyValue = declaration['body'] ?? const <dynamic>[];
      if (paramsValue is! List) {
        _fail('params must be a list', '$path.params');
      }
      if (bodyValue is! List) {
        _fail('body must be a list', '$path.body');
      }
      _validateAstBudget(bodyValue, '$path.body');
      final parameters = <String>[];
      final seen = <String>{};
      for (var i = 0; i < paramsValue.length; i++) {
        final value = paramsValue[i];
        if (value is! String ||
            value.isEmpty ||
            value.length > limits.maxNameLength) {
          _fail('parameter must be a non-empty string', '$path.params[$i]');
        }
        if (!seen.add(value)) {
          _fail('duplicate parameter "$value"', '$path.params[$i]');
        }
        parameters.add(value);
      }
      signatures.add(
        _FunctionSignature(
          id: id++,
          name: entry.key,
          parameters: List<String>.unmodifiable(parameters),
          body: List<dynamic>.from(bodyValue),
        ),
      );
    }
    return signatures;
  }

  Map<String, dynamic> _mapAt(String key, String path, {bool absent = false}) {
    final value = specification[key];
    if (value == null && absent) return <String, dynamic>{};
    if (value is! Map) _fail('$key must be an object', path);
    final entryLimit = switch (key) {
      'functions' => limits.maxFunctions,
      'buffers' || 'i32' || 'init' => limits.maxBuffers,
      _ => null,
    };
    final result = <String, dynamic>{};
    for (final entry in value.entries) {
      if (entryLimit != null && result.length >= entryLimit) {
        _fail('$key exceeds $entryLimit entries', path);
      }
      final name = entry.key;
      if (name is! String ||
          name.isEmpty ||
          name.length > limits.maxNameLength) {
        _fail('keys must be non-empty strings', path);
      }
      result[name] = entry.value;
    }
    return result;
  }

  int _size(dynamic value, String path) {
    if (value is! num ||
        !value.isFinite ||
        value.toInt() != value ||
        value < 0 ||
        value > _maxSafeInteger) {
      _fail('buffer size must be a non-negative integer', path);
    }
    return value.toInt();
  }

  int _initializerInt(dynamic value, String path) {
    if (value is! num ||
        !value.isFinite ||
        value.toInt() != value ||
        value < -_maxSafeInteger ||
        value > _maxSafeInteger) {
      _fail('initializer value must be a cross-platform safe integer', path);
    }
    return value.toInt();
  }

  void _validateAstBudget(List<dynamic> body, String path) {
    final stack = <({dynamic node, int depth})>[(node: body, depth: 1)];
    while (stack.isNotEmpty) {
      final current = stack.removeLast();
      _astNodeCount++;
      if (_astNodeCount > limits.maxAstNodes) {
        _fail('module exceeds ${limits.maxAstNodes} AST nodes', r'$.functions');
      }
      if (current.depth > limits.maxAstDepth) {
        _fail('AST nesting exceeds ${limits.maxAstDepth}', path);
      }
      final node = current.node;
      if (node is List) {
        for (final child in node) {
          stack.add((node: child, depth: current.depth + 1));
        }
      }
    }
  }

  Never _fail(String message, String path) {
    throw ComputeVmCompileException(message, path: path);
  }
}

final class _VmFunctionCompiler {
  _VmFunctionCompiler({
    required this.signature,
    required this.signatures,
    required this.functionByName,
    required this.u8Ids,
    required this.i32Ids,
    required this.hostIds,
    required this.constants,
    required this.constantIds,
    required this.callSites,
    required this.hostSites,
    required this.switchSites,
    required this.bulkSites,
    required this.limits,
    required this.instructionLimit,
    required this.switchTableEntryLimit,
  });

  final _FunctionSignature signature;
  final List<_FunctionSignature> signatures;
  final Map<String, int> functionByName;
  final Map<String, int> u8Ids;
  final Map<String, int> i32Ids;
  final Map<String, int> hostIds;
  final List<int> constants;
  final Map<int, int> constantIds;
  final List<_VmCallSite> callSites;
  final List<_VmHostSite> hostSites;
  final List<_VmSwitchSite> switchSites;
  final List<_VmBulkSite> bulkSites;
  final ComputeVmLimits limits;
  final int instructionLimit;
  final int switchTableEntryLimit;

  final List<int> _code = <int>[];
  final Map<String, int> _locals = <String, int>{};
  final List<List<int>> _breakPatchStack = <List<int>>[];
  final List<int> _continueTargetStack = <int>[];

  late int _localCount;
  late int _nextTemporary;
  late int _maxRegisterCount;
  var _switchTableEntries = 0;

  String get _bodyPath => '\$.functions.${signature.name}.body';
  int get _instructionCount => _code.length ~/ _instructionWidth;
  int get switchTableEntries => _switchTableEntries;

  _VmFunction compile() {
    for (final parameter in signature.parameters) {
      if (_locals.length >= limits.maxRegistersPerFunction) {
        _fail(
          'function exceeds ${limits.maxRegistersPerFunction} parameters',
          _bodyPath,
        );
      }
      _locals[parameter] = _locals.length;
    }
    _collectLocals(signature.body);
    _localCount = _locals.length;
    _nextTemporary = _localCount;
    _maxRegisterCount = _localCount;
    _compileBlock(signature.body, _bodyPath);
    _emit(_Op.returnValue, -1);

    final words = Int32List.fromList(_code);
    return _VmFunction(
      name: signature.name,
      parameterCount: signature.parameters.length,
      localCount: _localCount,
      registerCount: _maxRegisterCount,
      code: words,
      basicBlockStarts: _findBasicBlockStarts(words),
    );
  }

  void _collectLocals(dynamic node) {
    if (node is! List || node.isEmpty) return;
    final op = node.first;
    if (op is! String) {
      for (final child in node) {
        _collectLocals(child);
      }
      return;
    }
    if (op == 'set' && node.length > 1 && node[1] is String) {
      final name = node[1] as String;
      if (name.isEmpty || name.length > limits.maxNameLength) {
        _fail(
          'local name must contain 1-${limits.maxNameLength} characters',
          _bodyPath,
        );
      }
      _locals.putIfAbsent(name, () {
        if (_locals.length >= limits.maxRegistersPerFunction) {
          _fail(
            'function exceeds ${limits.maxRegistersPerFunction} locals',
            _bodyPath,
          );
        }
        return _locals.length;
      });
    }
    for (var i = 1; i < node.length; i++) {
      _collectLocals(node[i]);
    }
  }

  void _compileBlock(List<dynamic> statements, String path) {
    for (var i = 0; i < statements.length; i++) {
      _compileStatement(statements[i], '$path[$i]');
    }
  }

  void _compileStatement(dynamic node, String path) {
    final statement = _node(node, path, minimumLength: 1);
    final op = _string(statement[0], '$path[0]', what: 'statement opcode');
    switch (op) {
      case 'set':
        _length(statement, 3, path);
        final name = _string(statement[1], '$path[1]', what: 'local name');
        final slot = _locals[name];
        if (slot == null) _fail('unknown local "$name"', '$path[1]');
        final value = _compileExpression(statement[2], '$path[2]');
        _emit(_Op.move, slot, value);
        _releaseTemporary(value);
      case 'setu8':
        _length(statement, 4, path);
        final bufferId = _u8Id(statement[1], '$path[1]');
        final address = _compileExpression(statement[2], '$path[2]');
        final value = _compileExpression(statement[3], '$path[3]');
        _emit(_Op.storeU8, bufferId, address, value);
        _releaseTemporary(value);
        _releaseTemporary(address);
      case 'seti32':
        _length(statement, 4, path);
        final bufferId = _i32Id(statement[1], '$path[1]');
        final index = _compileExpression(statement[2], '$path[2]');
        final value = _compileExpression(statement[3], '$path[3]');
        _emit(_Op.storeI32, bufferId, index, value);
        _releaseTemporary(value);
        _releaseTemporary(index);
      case 'memset':
        _compileMemset(statement, path);
      case 'memlut':
        _compileMemlut(statement, path);
      case 'if':
        if (statement.length != 3 && statement.length != 4) {
          _fail('if expects condition, then, and optional else', path);
        }
        final condition = _compileExpression(statement[1], '$path[1]');
        final falseJump = _emit(_Op.jumpZero, condition, -1);
        _releaseTemporary(condition);
        _compileBlock(_block(statement[2], '$path[2]'), '$path[2]');
        if (statement.length == 4 && statement[3] != null) {
          final endJump = _emit(_Op.jump, -1);
          _patch(falseJump, 2, _instructionCount);
          _compileBlock(_block(statement[3], '$path[3]'), '$path[3]');
          _patch(endJump, 1, _instructionCount);
        } else {
          _patch(falseJump, 2, _instructionCount);
        }
      case 'while':
        _length(statement, 3, path);
        final conditionStart = _instructionCount;
        final condition = _compileExpression(statement[1], '$path[1]');
        final exitJump = _emit(_Op.jumpZero, condition, -1);
        _releaseTemporary(condition);
        final breaks = <int>[];
        _breakPatchStack.add(breaks);
        _continueTargetStack.add(conditionStart);
        _compileBlock(_block(statement[2], '$path[2]'), '$path[2]');
        _continueTargetStack.removeLast();
        _breakPatchStack.removeLast();
        _emit(_Op.jump, conditionStart);
        final exit = _instructionCount;
        _patch(exitJump, 2, exit);
        _patchJumps(breaks, exit);
      case 'repeat':
        _length(statement, 3, path);
        final count = _compileExpression(statement[1], '$path[1]');
        final firstCheck = _emit(_Op.jump, -1);
        final decrement = _instructionCount;
        _emit(_Op.decrement, count);
        final check = _instructionCount;
        _patch(firstCheck, 1, check);
        final exitJump = _emit(_Op.jumpLessEqualZero, count, -1);
        final breaks = <int>[];
        _breakPatchStack.add(breaks);
        _continueTargetStack.add(decrement);
        _compileBlock(_block(statement[2], '$path[2]'), '$path[2]');
        _continueTargetStack.removeLast();
        _breakPatchStack.removeLast();
        _emit(_Op.jump, decrement);
        final exit = _instructionCount;
        _patch(exitJump, 2, exit);
        _patchJumps(breaks, exit);
        _releaseTemporary(count);
      case 'switch':
        _compileSwitch(statement, path);
      case 'call':
        final result = _compileCall(statement, path);
        _releaseTemporary(result);
      case 'host':
        final result = _compileHost(statement, path);
        _releaseTemporary(result);
      case 'ret':
        if (statement.length > 2) {
          _fail('ret expects zero or one expression', path);
        }
        if (statement.length == 1 || statement[1] == null) {
          _emit(_Op.returnValue, -1);
        } else {
          final result = _compileExpression(statement[1], '$path[1]');
          _emit(_Op.returnValue, result);
          _releaseTemporary(result);
        }
      case 'break':
        _length(statement, 1, path);
        if (_breakPatchStack.isEmpty) {
          _fail('break is only valid inside a loop or switch', path);
        }
        _breakPatchStack.last.add(_emit(_Op.jump, -1));
      case 'continue':
        _length(statement, 1, path);
        if (_continueTargetStack.isEmpty) {
          _fail('continue is only valid inside a loop', path);
        }
        _emit(_Op.jump, _continueTargetStack.last);
      case 'block':
        _length(statement, 2, path);
        _compileBlock(_block(statement[1], '$path[1]'), '$path[1]');
      case 'nop':
        _length(statement, 1, path);
      default:
        _fail('unknown statement opcode "$op"', '$path[0]');
    }
  }

  void _compileMemset(List<dynamic> statement, String path) {
    _length(statement, 5, path);
    final destinationBufferId = _u8Id(statement[1], '$path[1]');
    final offset = _compileExpression(statement[2], '$path[2]');
    final length = _compileExpression(statement[3], '$path[3]');
    final value = _compileExpression(statement[4], '$path[4]');
    final site = _addBulkSite(
      _VmBulkSite(
        destinationBufferId: destinationBufferId,
        sourceBufferId: -1,
        lookupBufferId: -1,
        argumentRegisters: Int32List.fromList(<int>[offset, length, value]),
      ),
      path,
    );
    _emit(_Op.memset, site);
    _releaseTemporary(value);
    _releaseTemporary(length);
    _releaseTemporary(offset);
  }

  void _compileMemlut(List<dynamic> statement, String path) {
    _length(statement, 8, path);
    final destinationBufferId = _u8Id(statement[1], '$path[1]');
    final destinationOffset = _compileExpression(statement[2], '$path[2]');
    final sourceBufferId = _u8Id(statement[3], '$path[3]');
    final sourceOffset = _compileExpression(statement[4], '$path[4]');
    final length = _compileExpression(statement[5], '$path[5]');
    final lookupBufferId = _u8Id(statement[6], '$path[6]');
    final lookupOffset = _compileExpression(statement[7], '$path[7]');
    final site = _addBulkSite(
      _VmBulkSite(
        destinationBufferId: destinationBufferId,
        sourceBufferId: sourceBufferId,
        lookupBufferId: lookupBufferId,
        argumentRegisters: Int32List.fromList(<int>[
          destinationOffset,
          sourceOffset,
          length,
          lookupOffset,
        ]),
      ),
      path,
    );
    _emit(_Op.memlut, site);
    _releaseTemporary(lookupOffset);
    _releaseTemporary(length);
    _releaseTemporary(sourceOffset);
    _releaseTemporary(destinationOffset);
  }

  int _addBulkSite(_VmBulkSite site, String path) {
    if (bulkSites.length >= limits.maxBulkSites) {
      _fail('module exceeds ${limits.maxBulkSites} bulk sites', path);
    }
    final id = bulkSites.length;
    bulkSites.add(site);
    return id;
  }

  void _compileSwitch(List<dynamic> statement, String path) {
    if (statement.length != 3 && statement.length != 4) {
      _fail('switch expects selector, cases, and optional default', path);
    }
    final selector = _compileExpression(statement[1], '$path[1]');
    final rawCases = statement[2];
    if (rawCases is! List) _fail('switch cases must be a list', '$path[2]');

    final cases = <_SwitchCaseSource>[];
    final seen = <int>{};
    for (var i = 0; i < rawCases.length; i++) {
      final entry = _node(rawCases[i], '$path[2][$i]', minimumLength: 2);
      _length(entry, 2, '$path[2][$i]');
      final value = _integer(entry[0], '$path[2][$i][0]');
      final normalized = _int32(value);
      if (!seen.add(normalized)) {
        _fail('duplicate switch case $normalized', '$path[2][$i][0]');
      }
      cases.add(
        _SwitchCaseSource(
          key: normalized,
          body: _block(entry[1], '$path[2][$i][1]'),
          sourceIndex: i,
        ),
      );
    }

    // Reserve the site before compiling bodies. Nested switches can append
    // their own sites without colliding with this unfinished outer site.
    if (switchSites.length >= limits.maxSwitchSites) {
      _fail('module exceeds ${limits.maxSwitchSites} switch sites', path);
    }
    final siteId = switchSites.length;
    switchSites.add(_VmSwitchSite.pending());
    _emit(_Op.switchDispatch, selector, siteId);

    final targetsByKey = <int, int>{};
    final endJumps = <int>[];
    final breaks = <int>[];
    _breakPatchStack.add(breaks);
    for (final caseSource in cases) {
      targetsByKey[caseSource.key] = _instructionCount;
      _compileBlock(caseSource.body, '$path[2][${caseSource.sourceIndex}][1]');
      endJumps.add(_emit(_Op.jump, -1));
    }
    final defaultTarget = _instructionCount;
    if (statement.length == 4 && statement[3] != null) {
      _compileBlock(_block(statement[3], '$path[3]'), '$path[3]');
    }
    _breakPatchStack.removeLast();
    final end = _instructionCount;
    _patchJumps(endJumps, end);
    _patchJumps(breaks, end);
    switchSites[siteId] = _buildSwitchSite(targetsByKey, defaultTarget);
    _releaseTemporary(selector);
  }

  _VmSwitchSite _buildSwitchSite(
    Map<int, int> targetsByKey,
    int defaultTarget,
  ) {
    final keys = targetsByKey.keys.toList()..sort();
    if (keys.isEmpty) {
      return _VmSwitchSite.binarySearch(
        defaultTarget: defaultTarget,
        keys: Int32List(0),
        targets: Int32List(0),
      );
    }

    final minimum = keys.first;
    final span = keys.last - minimum + 1;
    const maximumJumpTableEntries = 65536;
    final useJumpTable =
        span <= maximumJumpTableEntries && span <= keys.length * 2;
    if (useJumpTable) {
      _reserveSwitchTableEntries(span);
      final targets = Int32List(span);
      targets.fillRange(0, targets.length, defaultTarget);
      for (final key in keys) {
        targets[key - minimum] = targetsByKey[key]!;
      }
      return _VmSwitchSite.jumpTable(
        defaultTarget: defaultTarget,
        minimumKey: minimum,
        targets: targets,
      );
    }

    _reserveSwitchTableEntries(keys.length * 2);
    return _VmSwitchSite.binarySearch(
      defaultTarget: defaultTarget,
      keys: Int32List.fromList(keys),
      targets: Int32List.fromList(
        keys.map((key) => targetsByKey[key]!).toList(growable: false),
      ),
    );
  }

  int _compileExpression(dynamic node, String path) {
    if (node is bool) return _emitConstant(node ? 1 : 0);
    if (node is num) return _emitConstant(_integer(node, path));
    final expression = _node(node, path, minimumLength: 1);
    final op = _string(expression[0], '$path[0]', what: 'expression opcode');
    switch (op) {
      case 'var':
        _length(expression, 2, path);
        final name = _string(expression[1], '$path[1]', what: 'local name');
        final slot = _locals[name];
        if (slot == null) _fail('unknown local "$name"', '$path[1]');
        final result = _allocateTemporary();
        _emit(_Op.move, result, slot);
        return result;
      case 'lit':
        _length(expression, 2, path);
        return _emitConstant(_integer(expression[1], '$path[1]'));
      case 'u8':
        _length(expression, 3, path);
        final bufferId = _u8Id(expression[1], '$path[1]');
        final address = _compileExpression(expression[2], '$path[2]');
        _emit(_Op.loadU8, address, bufferId, address);
        return address;
      case 'i32':
        _length(expression, 3, path);
        final bufferId = _i32Id(expression[1], '$path[1]');
        final index = _compileExpression(expression[2], '$path[2]');
        _emit(_Op.loadI32, index, bufferId, index);
        return index;
      case 'call':
        return _compileCall(expression, path);
      case 'host':
        return _compileHost(expression, path);
      case '+':
        return _binary(expression, path, _Op.add);
      case '-':
        if (expression.length == 2) {
          final value = _compileExpression(expression[1], '$path[1]');
          _emit(_Op.negate, value, value);
          return value;
        }
        return _binary(expression, path, _Op.subtract);
      case '*':
        return _binary(expression, path, _Op.multiply);
      case '/':
        return _binary(expression, path, _Op.divide);
      case '%':
        return _binary(expression, path, _Op.modulo);
      case '&':
        return _binary(expression, path, _Op.bitAnd);
      case '|':
        return _binary(expression, path, _Op.bitOr);
      case '^':
        return _binary(expression, path, _Op.bitXor);
      case '~':
        return _unary(expression, path, _Op.bitNot);
      case '<<':
        return _binary(expression, path, _Op.shiftLeft);
      case '>>':
        return _binary(expression, path, _Op.shiftRight);
      case '==':
        return _binary(expression, path, _Op.equal);
      case '!=':
        return _binary(expression, path, _Op.notEqual);
      case '<':
        return _binary(expression, path, _Op.less);
      case '<=':
        return _binary(expression, path, _Op.lessEqual);
      case '>':
        return _binary(expression, path, _Op.greater);
      case '>=':
        return _binary(expression, path, _Op.greaterEqual);
      case 'not':
        return _unary(expression, path, _Op.logicalNot);
      case 'min':
        return _binary(expression, path, _Op.minimum);
      case 'max':
        return _binary(expression, path, _Op.maximum);
      case 'and':
        return _compileAnd(expression, path);
      case 'or':
        return _compileOr(expression, path);
      case '?:':
        return _compileConditional(expression, path);
      default:
        _fail('unknown expression opcode "$op"', '$path[0]');
    }
  }

  int _binary(List<dynamic> expression, String path, int opcode) {
    _length(expression, 3, path);
    final left = _compileExpression(expression[1], '$path[1]');
    final right = _compileExpression(expression[2], '$path[2]');
    _emit(opcode, left, left, right);
    _releaseTemporary(right);
    return left;
  }

  int _unary(List<dynamic> expression, String path, int opcode) {
    _length(expression, 2, path);
    final value = _compileExpression(expression[1], '$path[1]');
    _emit(opcode, value, value);
    return value;
  }

  int _compileAnd(List<dynamic> expression, String path) {
    _length(expression, 3, path);
    final result = _compileExpression(expression[1], '$path[1]');
    final falseJump = _emit(_Op.jumpZero, result, -1);
    final right = _compileExpression(expression[2], '$path[2]');
    _emit(_Op.logicalNot, right, right);
    _emit(_Op.logicalNot, right, right);
    _emit(_Op.move, result, right);
    _releaseTemporary(right);
    final endJump = _emit(_Op.jump, -1);
    _patch(falseJump, 2, _instructionCount);
    _emit(_Op.constant, result, _constantId(0));
    _patch(endJump, 1, _instructionCount);
    return result;
  }

  int _compileOr(List<dynamic> expression, String path) {
    _length(expression, 3, path);
    final result = _compileExpression(expression[1], '$path[1]');
    final trueJump = _emit(_Op.jumpNonZero, result, -1);
    final right = _compileExpression(expression[2], '$path[2]');
    _emit(_Op.logicalNot, right, right);
    _emit(_Op.logicalNot, right, right);
    _emit(_Op.move, result, right);
    _releaseTemporary(right);
    final endJump = _emit(_Op.jump, -1);
    _patch(trueJump, 2, _instructionCount);
    _emit(_Op.constant, result, _constantId(1));
    _patch(endJump, 1, _instructionCount);
    return result;
  }

  int _compileConditional(List<dynamic> expression, String path) {
    _length(expression, 4, path);
    final result = _compileExpression(expression[1], '$path[1]');
    final falseJump = _emit(_Op.jumpZero, result, -1);
    final whenTrue = _compileExpression(expression[2], '$path[2]');
    _emit(_Op.move, result, whenTrue);
    _releaseTemporary(whenTrue);
    final endJump = _emit(_Op.jump, -1);
    _patch(falseJump, 2, _instructionCount);
    final whenFalse = _compileExpression(expression[3], '$path[3]');
    _emit(_Op.move, result, whenFalse);
    _releaseTemporary(whenFalse);
    _patch(endJump, 1, _instructionCount);
    return result;
  }

  int _compileCall(List<dynamic> expression, String path) {
    if (expression.length != 2 && expression.length != 3) {
      _fail('call expects a function name and optional argument list', path);
    }
    final name = _string(expression[1], '$path[1]', what: 'function name');
    final functionId = functionByName[name];
    if (functionId == null) {
      _fail('call to unknown function "$name"', '$path[1]');
    }
    final arguments = expression.length == 3
        ? _block(expression[2], '$path[2]')
        : const <dynamic>[];
    final expected = signatures[functionId].parameters.length;
    if (arguments.length != expected) {
      _fail(
        'function "$name" expects $expected arguments, got ${arguments.length}',
        path,
      );
    }
    final registers = <int>[];
    for (var i = 0; i < arguments.length; i++) {
      registers.add(_compileExpression(arguments[i], '$path[2][$i]'));
    }
    final result = registers.isEmpty ? _allocateTemporary() : registers.first;
    if (callSites.length >= limits.maxCallSites) {
      _fail('module exceeds ${limits.maxCallSites} call sites', path);
    }
    final site = callSites.length;
    callSites.add(
      _VmCallSite(
        functionId: functionId,
        argumentRegisters: Int32List.fromList(registers),
      ),
    );
    _emit(_Op.call, result, site);
    for (var i = registers.length - 1; i >= 1; i--) {
      _releaseTemporary(registers[i]);
    }
    return result;
  }

  int _compileHost(List<dynamic> expression, String path) {
    if (expression.length != 2 && expression.length != 3) {
      _fail('host expects a host name and optional argument list', path);
    }
    final name = _string(expression[1], '$path[1]', what: 'host name');
    final hostId = hostIds[name];
    if (hostId == null) {
      _fail('unknown host function "$name"', '$path[1]');
    }
    final arguments = expression.length == 3
        ? _block(expression[2], '$path[2]')
        : const <dynamic>[];
    final registers = <int>[];
    for (var i = 0; i < arguments.length; i++) {
      registers.add(_compileExpression(arguments[i], '$path[2][$i]'));
    }
    final result = registers.isEmpty ? _allocateTemporary() : registers.first;
    if (hostSites.length >= limits.maxHostSites) {
      _fail('module exceeds ${limits.maxHostSites} host sites', path);
    }
    final site = hostSites.length;
    hostSites.add(
      _VmHostSite(
        hostId: hostId,
        argumentRegisters: Int32List.fromList(registers),
      ),
    );
    _emit(_Op.host, result, site);
    for (var i = registers.length - 1; i >= 1; i--) {
      _releaseTemporary(registers[i]);
    }
    return result;
  }

  int _emitConstant(int value) {
    final register = _allocateTemporary();
    _emit(_Op.constant, register, _constantId(_int32(value)));
    return register;
  }

  int _constantId(int value) {
    final normalized = _int32(value);
    return constantIds.putIfAbsent(normalized, () {
      if (constants.length >= limits.maxConstants) {
        _fail(
          'module exceeds ${limits.maxConstants} unique constants',
          _bodyPath,
        );
      }
      constants.add(normalized);
      return constants.length - 1;
    });
  }

  int _allocateTemporary() {
    if (_nextTemporary >= limits.maxRegistersPerFunction) {
      _fail(
        'function exceeds ${limits.maxRegistersPerFunction} registers',
        _bodyPath,
      );
    }
    final register = _nextTemporary++;
    if (_nextTemporary > _maxRegisterCount) {
      _maxRegisterCount = _nextTemporary;
    }
    return register;
  }

  void _releaseTemporary(int register) {
    if (register < _localCount || register != _nextTemporary - 1) {
      throw StateError(
        'internal register allocation error in ${signature.name}: $register',
      );
    }
    _nextTemporary--;
  }

  int _emit(int opcode, [int a = 0, int b = 0, int c = 0]) {
    if (_instructionCount >= instructionLimit) {
      _fail('module exceeds ${limits.maxInstructions} instructions', _bodyPath);
    }
    final index = _instructionCount;
    _code.addAll(<int>[opcode, a, b, c]);
    return index;
  }

  void _patch(int instruction, int operand, int value) {
    _code[instruction * _instructionWidth + operand] = value;
  }

  void _patchJumps(List<int> jumps, int target) {
    for (final jump in jumps) {
      _patch(jump, 1, target);
    }
  }

  int _u8Id(dynamic value, String path) {
    final name = _string(value, path, what: 'byte buffer name');
    final id = u8Ids[name];
    if (id == null) _fail('unknown u8 buffer "$name"', path);
    return id;
  }

  int _i32Id(dynamic value, String path) {
    final name = _string(value, path, what: 'word buffer name');
    final id = i32Ids[name];
    if (id == null) _fail('unknown i32 buffer "$name"', path);
    return id;
  }

  List<dynamic> _node(
    dynamic value,
    String path, {
    required int minimumLength,
  }) {
    if (value is! List || value.length < minimumLength) {
      _fail('expected a non-empty AST node', path);
    }
    return value;
  }

  List<dynamic> _block(dynamic value, String path) {
    if (value is! List) _fail('expected a statement/expression list', path);
    return List<dynamic>.from(value);
  }

  String _string(dynamic value, String path, {required String what}) {
    if (value is! String ||
        value.isEmpty ||
        value.length > limits.maxNameLength) {
      _fail('$what must contain 1-${limits.maxNameLength} characters', path);
    }
    return value;
  }

  int _integer(dynamic value, String path) {
    if (value is! num ||
        !value.isFinite ||
        value.toInt() != value ||
        value < -_maxSafeInteger ||
        value > _maxSafeInteger) {
      _fail('expected a cross-platform safe integer', path);
    }
    return value.toInt();
  }

  void _length(List<dynamic> node, int expected, String path) {
    if (node.length != expected) {
      _fail('expected ${expected - 1} operands, got ${node.length - 1}', path);
    }
  }

  Never _fail(String message, String path) {
    throw ComputeVmCompileException(message, path: path);
  }

  void _reserveSwitchTableEntries(int count) {
    if (count > switchTableEntryLimit - _switchTableEntries) {
      _fail(
        'module exceeds ${limits.maxSwitchTableEntries} switch table entries',
        _bodyPath,
      );
    }
    _switchTableEntries += count;
  }

  Int32List _findBasicBlockStarts(Int32List code) {
    final instructionCount = code.length ~/ _instructionWidth;
    final starts = <int>{if (instructionCount > 0) 0};
    for (var pc = 0; pc < instructionCount; pc++) {
      final base = pc * _instructionWidth;
      final opcode = code[base];
      switch (opcode) {
        case _Op.jump:
          starts.add(code[base + 1]);
          if (pc + 1 < instructionCount) starts.add(pc + 1);
        case _Op.jumpZero || _Op.jumpNonZero || _Op.jumpLessEqualZero:
          starts.add(code[base + 2]);
          if (pc + 1 < instructionCount) starts.add(pc + 1);
        case _Op.switchDispatch:
          final site = switchSites[code[base + 2]];
          starts.add(site.defaultTarget);
          starts.addAll(site.targets);
          if (pc + 1 < instructionCount) starts.add(pc + 1);
        case _Op.returnValue:
          if (pc + 1 < instructionCount) starts.add(pc + 1);
      }
    }
    final ordered = starts.where((value) {
      return value >= 0 && value < instructionCount;
    }).toList()..sort();
    return Int32List.fromList(ordered);
  }
}

final class _SwitchCaseSource {
  const _SwitchCaseSource({
    required this.key,
    required this.body,
    required this.sourceIndex,
  });

  final int key;
  final List<dynamic> body;
  final int sourceIndex;
}
