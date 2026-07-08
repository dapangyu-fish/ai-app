/// Compute kernel — a general-purpose imperative VM defined in JSON and
/// compiled to Dart closures at load time (near-native speed).
///
/// Motivation (docs/nesd-port-feasibility.md, tier T7): interpreted jsonlogic
/// tops out around 60k steps/s — three orders of magnitude short of what an
/// emulator core needs. This kernel closes that gap WITHOUT a purpose-built
/// bridge: a JSON app declares a `compute` module (typed buffers + functions
/// of a small imperative AST); the framework compiles it once into a tree of
/// `int Function(_Ctx)` closures that run at ordinary Dart speed. The NES core
/// (or any CHIP-8 / GB / DSP / procedural workload) is then *authored as data*
/// for this kernel — that is the "true end-to-end JSON port".
///
/// Deliberately dependency-free (no Flutter imports) so it unit-tests under a
/// bare `dart run`. Host bindings (framebuffer present, input, audio push) are
/// injected via [ComputeProgram.hosts].
library;

import 'dart:typed_data';

/// Signals returned up the statement tree to implement control flow without
/// exceptions (exceptions in the hot loop would be far too slow).
const int _normal = 0;
const int _breakSig = 1;
const int _continueSig = 2;
const int _returnSig = 3;

typedef _Expr = int Function(_Ctx c);
typedef _Stmt = int Function(_Ctx c);

/// Host callback: receives the evaluated int args, returns an int (0 if void).
typedef HostFn = int Function(List<int> args);

class ComputeException implements Exception {
  ComputeException(this.message);
  final String message;
  @override
  String toString() => 'ComputeException: $message';
}

/// Raised when a single [ComputeProgram.call] exceeds its instruction budget —
/// a safety valve so a runaway program cannot hang the UI isolate.
class ComputeBudgetExceeded implements Exception {
  ComputeBudgetExceeded(this.budget);
  final int budget;
  @override
  String toString() => 'ComputeBudgetExceeded($budget)';
}

class _Func {
  _Func(this.name, this.paramCount, this.localCount);
  final String name;
  final int paramCount;
  int localCount;
  late _Stmt body;
}

/// Mutable execution context shared by every compiled closure of one program.
/// Buffers and host bindings are captured directly in the compiled closures,
/// so the context only carries per-run mutable state.
class _Ctx {
  Int32List locals = Int32List(0);
  final List<Int32List> frameStack = <Int32List>[];
  int retVal = 0;
  int budget = 0;
}

/// A compiled compute module. Build with [ComputeProgram.compile], then drive
/// with [call] from framework code (once per frame/tick).
class ComputeProgram {
  ComputeProgram._(this.u8, this.i32, this._funcs, this.hosts);

  /// Byte buffers (RAM, PRG-ROM, framebuffer, …), addressable by [_setu8]/[_u8].
  final Map<String, Uint8List> u8;

  /// Word buffers (register files, palettes, scratch), addressable by index.
  final Map<String, Int32List> i32;

  final Map<String, _Func> _funcs;

  /// Native host bindings callable from the program via `["host", name, args]`.
  final Map<String, HostFn> hosts;

  final _Ctx _ctx = _Ctx();

  Uint8List buffer(String name) {
    final b = u8[name];
    if (b == null) throw ComputeException('unknown u8 buffer: $name');
    return b;
  }

  Int32List words(String name) {
    final b = i32[name];
    if (b == null) throw ComputeException('unknown i32 buffer: $name');
    return b;
  }

  /// Invoke function [name] with [args]; returns its `ret` value (0 if none).
  /// [budget] caps executed loop iterations + calls; exceeding it throws
  /// [ComputeBudgetExceeded].
  int call(String name, {List<int> args = const [], int budget = 50000000}) {
    final f = _funcs[name];
    if (f == null) throw ComputeException('unknown function: $name');
    if (args.length != f.paramCount) {
      throw ComputeException(
        'function $name expects ${f.paramCount} args, got ${args.length}',
      );
    }
    _ctx.budget = budget;
    _ctx.frameStack.clear();
    final frame = Int32List(f.localCount);
    for (var i = 0; i < args.length; i++) {
      frame[i] = args[i];
    }
    _ctx.locals = frame;
    _ctx.retVal = 0;
    f.body(_ctx);
    return _ctx.retVal;
  }

  // ------------------------------------------------------------------ compile

  static ComputeProgram compile(
    Map<String, dynamic> spec, {
    Map<String, HostFn> hosts = const {},
  }) {
    final u8 = <String, Uint8List>{};
    final rawBuf = (spec['buffers'] as Map?) ?? const {};
    rawBuf.forEach((k, v) {
      u8['$k'] = Uint8List((v as num).toInt());
    });
    final i32 = <String, Int32List>{};
    final rawI32 = (spec['i32'] as Map?) ?? const {};
    rawI32.forEach((k, v) {
      i32['$k'] = Int32List((v as num).toInt());
    });

    final funcSpecs = (spec['functions'] as Map?) ?? const {};
    final funcs = <String, _Func>{};
    // First pass: register signatures (so calls can resolve forward refs).
    funcSpecs.forEach((k, v) {
      final fn = (v as Map).cast<String, dynamic>();
      final params = (fn['params'] as List?)?.cast<String>() ?? const [];
      funcs['$k'] = _Func('$k', params.length, params.length);
    });

    final compiler = _Compiler(u8, i32, funcs, hosts);
    funcSpecs.forEach((k, v) {
      final fn = (v as Map).cast<String, dynamic>();
      final params = (fn['params'] as List?)?.cast<String>() ?? const [];
      final body = (fn['body'] as List?) ?? const [];
      final f = funcs['$k']!;
      compiler.beginFunction(params);
      f.body = compiler.compileBlock(body);
      f.localCount = compiler.endFunction();
    });

    return ComputeProgram._(u8, i32, funcs, hosts);
  }
}

/// Compiles a function's statement/expression AST into closures, resolving
/// local variable names to dense Int32List slot indices for hot-path speed.
class _Compiler {
  _Compiler(this.u8, this.i32, this.funcs, this.hosts);

  final Map<String, Uint8List> u8;
  final Map<String, Int32List> i32;
  final Map<String, _Func> funcs;
  final Map<String, HostFn> hosts;

  Map<String, int> _slots = {};
  int _nextSlot = 0;

  void beginFunction(List<String> params) {
    _slots = {};
    _nextSlot = 0;
    for (final p in params) {
      _slots[p] = _nextSlot++;
    }
  }

  int endFunction() => _nextSlot;

  int _slotFor(String name) => _slots.putIfAbsent(name, () => _nextSlot++);

  // ----------------------------------------------------------- statements

  _Stmt compileBlock(List<dynamic> body) {
    final stmts = <_Stmt>[];
    for (final s in body) {
      stmts.add(_compileStmt(s));
    }
    final n = stmts.length;
    if (n == 0) return (c) => _normal;
    if (n == 1) return stmts[0];
    final arr = stmts;
    return (c) {
      for (var i = 0; i < n; i++) {
        final sig = arr[i](c);
        if (sig != _normal) return sig;
      }
      return _normal;
    };
  }

  _Stmt _compileStmt(dynamic node) {
    if (node is! List || node.isEmpty) {
      throw ComputeException('bad statement: $node');
    }
    final op = node[0] as String;
    switch (op) {
      case 'set':
        final slot = _slotFor(node[1] as String);
        final val = _compileExpr(node[2]);
        return (c) {
          c.locals[slot] = val(c);
          return _normal;
        };
      case 'setu8':
        final buf = _buf(node[1] as String);
        final addr = _compileExpr(node[2]);
        final val = _compileExpr(node[3]);
        final mask = buf.length - 1;
        final pow2 = buf.isNotEmpty && (buf.length & mask) == 0;
        return pow2
            ? (c) {
                buf[addr(c) & mask] = val(c);
                return _normal;
              }
            : (c) {
                final a = addr(c);
                if (a >= 0 && a < buf.length) buf[a] = val(c);
                return _normal;
              };
      case 'seti32':
        final buf = _words(node[1] as String);
        final idx = _compileExpr(node[2]);
        final val = _compileExpr(node[3]);
        return (c) {
          final a = idx(c);
          if (a >= 0 && a < buf.length) buf[a] = val(c);
          return _normal;
        };
      case 'if':
        final cond = _compileExpr(node[1]);
        final thenB = compileBlock((node[2] as List?) ?? const []);
        final elseB = node.length > 3 && node[3] != null
            ? compileBlock(node[3] as List)
            : null;
        if (elseB == null) {
          return (c) => cond(c) != 0 ? thenB(c) : _normal;
        }
        return (c) => cond(c) != 0 ? thenB(c) : elseB(c);
      case 'while':
        final cond = _compileExpr(node[1]);
        final body = compileBlock((node[2] as List?) ?? const []);
        return (c) {
          while (cond(c) != 0) {
            if (--c.budget <= 0) throw ComputeBudgetExceeded(0);
            final sig = body(c);
            if (sig == _breakSig) break;
            if (sig == _returnSig) return _returnSig;
          }
          return _normal;
        };
      case 'dowhile':
        final body = compileBlock((node[1] as List?) ?? const []);
        final cond = _compileExpr(node[2]);
        return (c) {
          do {
            if (--c.budget <= 0) throw ComputeBudgetExceeded(0);
            final sig = body(c);
            if (sig == _breakSig) break;
            if (sig == _returnSig) return _returnSig;
          } while (cond(c) != 0);
          return _normal;
        };
      case 'repeat': // ["repeat", countExpr, [body]] — fixed-count loop
        final count = _compileExpr(node[1]);
        final body = compileBlock((node[2] as List?) ?? const []);
        return (c) {
          final n = count(c);
          for (var i = 0; i < n; i++) {
            if (--c.budget <= 0) throw ComputeBudgetExceeded(0);
            final sig = body(c);
            if (sig == _breakSig) break;
            if (sig == _returnSig) return _returnSig;
          }
          return _normal;
        };
      case 'switch':
        return _compileSwitch(node);
      case 'call': // statement form: discard return value
        final expr = _compileCall(node);
        return (c) {
          expr(c);
          return _normal;
        };
      case 'host':
        final expr = _compileHost(node);
        return (c) {
          expr(c);
          return _normal;
        };
      case 'ret':
        if (node.length > 1 && node[1] != null) {
          final val = _compileExpr(node[1]);
          return (c) {
            c.retVal = val(c);
            return _returnSig;
          };
        }
        return (c) {
          c.retVal = 0;
          return _returnSig;
        };
      case 'break':
        return (c) => _breakSig;
      case 'continue':
        return (c) => _continueSig;
      case 'block':
        return compileBlock((node[1] as List?) ?? const []);
      case 'nop':
        return (c) => _normal;
      default:
        throw ComputeException('unknown statement op: $op');
    }
  }

  _Stmt _compileSwitch(List<dynamic> node) {
    // ["switch", expr, [[val,[body]], ...], [default?]]
    final sel = _compileExpr(node[1]);
    final cases = <int, _Stmt>{};
    for (final entry in (node[2] as List)) {
      final e = entry as List;
      cases[(e[0] as num).toInt()] = compileBlock((e[1] as List?) ?? const []);
    }
    final def = node.length > 3 && node[3] != null
        ? compileBlock(node[3] as List)
        : null;
    return (c) {
      final s = cases[sel(c)];
      if (s != null) return s(c);
      if (def != null) return def(c);
      return _normal;
    };
  }

  // ---------------------------------------------------------- expressions

  _Expr _compileExpr(dynamic node) {
    if (node is num) {
      final v = node.toInt();
      return (c) => v;
    }
    if (node is bool) {
      final v = node ? 1 : 0;
      return (c) => v;
    }
    if (node is! List || node.isEmpty) {
      throw ComputeException('bad expression: $node');
    }
    final op = node[0] as String;
    switch (op) {
      case 'var':
        final slot = _slotFor(node[1] as String);
        return (c) => c.locals[slot];
      case 'lit':
        final v = (node[1] as num).toInt();
        return (c) => v;
      case 'u8':
        final buf = _buf(node[1] as String);
        final addr = _compileExpr(node[2]);
        final mask = buf.length - 1;
        final pow2 = buf.isNotEmpty && (buf.length & mask) == 0;
        return pow2
            ? (c) => buf[addr(c) & mask]
            : (c) {
                final a = addr(c);
                return (a >= 0 && a < buf.length) ? buf[a] : 0;
              };
      case 'i32':
        final buf = _words(node[1] as String);
        final idx = _compileExpr(node[2]);
        return (c) {
          final a = idx(c);
          return (a >= 0 && a < buf.length) ? buf[a] : 0;
        };
      case 'call':
        return _compileCall(node);
      case 'host':
        return _compileHost(node);
      // arithmetic
      case '+':
        return _bin(node, (a, b) => a + b);
      case '-':
        if (node.length == 2) {
          final a = _compileExpr(node[1]);
          return (c) => -a(c);
        }
        return _bin(node, (a, b) => a - b);
      case '*':
        return _bin(node, (a, b) => a * b);
      case '/':
        return _bin(node, (a, b) => b == 0 ? 0 : a ~/ b);
      case '%':
        return _bin(node, (a, b) => b == 0 ? 0 : a % b);
      // bitwise
      case '&':
        return _bin(node, (a, b) => a & b);
      case '|':
        return _bin(node, (a, b) => a | b);
      case '^':
        return _bin(node, (a, b) => a ^ b);
      case '~':
        final a = _compileExpr(node[1]);
        return (c) => ~a(c);
      case '<<':
        return _bin(node, (a, b) => (a << (b & 31)));
      case '>>': // logical shift on 32-bit
        return _bin(node, (a, b) => (a & 0xFFFFFFFF) >> (b & 31));
      // compare / logic (return 1/0)
      case '==':
        return _bin(node, (a, b) => a == b ? 1 : 0);
      case '!=':
        return _bin(node, (a, b) => a != b ? 1 : 0);
      case '<':
        return _bin(node, (a, b) => a < b ? 1 : 0);
      case '<=':
        return _bin(node, (a, b) => a <= b ? 1 : 0);
      case '>':
        return _bin(node, (a, b) => a > b ? 1 : 0);
      case '>=':
        return _bin(node, (a, b) => a >= b ? 1 : 0);
      case 'and':
        final a = _compileExpr(node[1]);
        final b = _compileExpr(node[2]);
        return (c) => (a(c) != 0 && b(c) != 0) ? 1 : 0;
      case 'or':
        final a = _compileExpr(node[1]);
        final b = _compileExpr(node[2]);
        return (c) => (a(c) != 0 || b(c) != 0) ? 1 : 0;
      case 'not':
        final a = _compileExpr(node[1]);
        return (c) => a(c) == 0 ? 1 : 0;
      case '?:':
        final cond = _compileExpr(node[1]);
        final a = _compileExpr(node[2]);
        final b = _compileExpr(node[3]);
        return (c) => cond(c) != 0 ? a(c) : b(c);
      case 'min':
        return _bin(node, (a, b) => a < b ? a : b);
      case 'max':
        return _bin(node, (a, b) => a > b ? a : b);
      default:
        throw ComputeException('unknown expression op: $op');
    }
  }

  _Expr _bin(List<dynamic> node, int Function(int, int) f) {
    final a = _compileExpr(node[1]);
    final b = _compileExpr(node[2]);
    return (c) => f(a(c), b(c));
  }

  _Expr _compileCall(List<dynamic> node) {
    final fname = node[1] as String;
    final f = funcs[fname];
    if (f == null) throw ComputeException('call to unknown function: $fname');
    final argNodes = (node.length > 2 ? node[2] as List : const []);
    final argFns = argNodes.map(_compileExpr).toList();
    if (argFns.length != f.paramCount) {
      throw ComputeException(
        'call $fname: ${argFns.length} args vs ${f.paramCount} params',
      );
    }
    final n = argFns.length;
    return (c) {
      final frame = Int32List(f.localCount);
      for (var i = 0; i < n; i++) {
        frame[i] = argFns[i](c);
      }
      c.frameStack.add(c.locals);
      c.locals = frame;
      final savedRet = c.retVal;
      c.retVal = 0;
      if (--c.budget <= 0) throw ComputeBudgetExceeded(0);
      f.body(c);
      final r = c.retVal;
      c.locals = c.frameStack.removeLast();
      c.retVal = savedRet;
      return r;
    };
  }

  _Expr _compileHost(List<dynamic> node) {
    final hname = node[1] as String;
    final fn = hosts[hname];
    if (fn == null) throw ComputeException('unknown host fn: $hname');
    final argNodes = (node.length > 2 ? node[2] as List : const []);
    final argFns = argNodes.map(_compileExpr).toList();
    final n = argFns.length;
    return (c) {
      final args = List<int>.filled(n, 0);
      for (var i = 0; i < n; i++) {
        args[i] = argFns[i](c);
      }
      return fn(args);
    };
  }

  Uint8List _buf(String name) {
    final b = u8[name];
    if (b == null) throw ComputeException('unknown u8 buffer: $name');
    return b;
  }

  Int32List _words(String name) {
    final b = i32[name];
    if (b == null) throw ComputeException('unknown i32 buffer: $name');
    return b;
  }
}
