part of '../compute_vm.dart';

final class _ComputeVmRunner {
  _ComputeVmRunner({
    required this.module,
    required this.u8,
    required this.u8Masks,
    required this.i32,
    required this.hosts,
    required this.limits,
    required int budget,
  }) : _initialBudget = budget,
       _remainingBudget = budget;

  final _VmModule module;
  final List<Uint8List> u8;
  final List<int> u8Masks;
  final List<Int32List> i32;
  final Map<String, ComputeVmHostFunction> hosts;
  final ComputeVmLimits limits;
  final int _initialBudget;
  int _remainingBudget;

  int call(int functionId, List<int> arguments) {
    final entry = module.functions[functionId];
    if (entry.registerCount > limits.maxStackWords) {
      throw ComputeVmRuntimeException(
        'entry frame requires ${entry.registerCount} stack words, '
        'limit is ${limits.maxStackWords}',
      );
    }
    var stackWords = entry.registerCount;
    final entryRegisters = Int32List(entry.registerCount);
    for (var i = 0; i < arguments.length; i++) {
      entryRegisters[i] = arguments[i];
    }
    final stack = <_VmFrame>[
      _VmFrame(function: entry, registers: entryRegisters, returnRegister: -1),
    ];

    while (stack.isNotEmpty) {
      final frame = stack.last;
      final pc = frame.pc;
      if (_remainingBudget == 0) {
        throw ComputeVmBudgetExceeded(
          budget: _initialBudget,
          executedInstructions: _initialBudget,
          function: frame.function.name,
          instruction: pc,
        );
      }
      if (pc < 0 || pc >= frame.function.instructionCount) {
        throw ComputeVmRuntimeException(
          'invalid instruction pointer ${frame.function.name}#$pc',
        );
      }
      _remainingBudget--;
      final code = frame.function.code;
      final base = pc * _instructionWidth;
      final opcode = code[base];
      final a = code[base + 1];
      final b = code[base + 2];
      final c = code[base + 3];
      final registers = frame.registers;
      frame.pc = pc + 1;

      switch (opcode) {
        case _Op.constant:
          registers[a] = module.constants[b];
        case _Op.move:
          registers[a] = registers[b];
        case _Op.loadU8:
          registers[a] = _readByte(u8[b], u8Masks[b], registers[c]);
        case _Op.storeU8:
          _writeByte(u8[a], u8Masks[a], registers[b], registers[c]);
        case _Op.loadI32:
          final index = registers[c];
          registers[a] = index >= 0 && index < i32[b].length
              ? i32[b][index]
              : 0;
        case _Op.storeI32:
          final index = registers[b];
          if (index >= 0 && index < i32[a].length) {
            i32[a][index] = registers[c];
          }
        case _Op.add:
          registers[a] = registers[b] + registers[c];
        case _Op.subtract:
          registers[a] = registers[b] - registers[c];
        case _Op.multiply:
          registers[a] = _multiplyInt32(registers[b], registers[c]);
        case _Op.divide:
          final divisor = registers[c];
          registers[a] = divisor == 0 ? 0 : registers[b] ~/ divisor;
        case _Op.modulo:
          final divisor = registers[c];
          registers[a] = divisor == 0 ? 0 : registers[b] % divisor;
        case _Op.negate:
          registers[a] = -registers[b];
        case _Op.bitAnd:
          registers[a] = registers[b] & registers[c];
        case _Op.bitOr:
          registers[a] = registers[b] | registers[c];
        case _Op.bitXor:
          registers[a] = registers[b] ^ registers[c];
        case _Op.bitNot:
          registers[a] = ~registers[b];
        case _Op.shiftLeft:
          registers[a] = registers[b] << (registers[c] & 31);
        case _Op.shiftRight:
          registers[a] = (registers[b] & 0xFFFFFFFF) >> (registers[c] & 31);
        case _Op.equal:
          registers[a] = registers[b] == registers[c] ? 1 : 0;
        case _Op.notEqual:
          registers[a] = registers[b] != registers[c] ? 1 : 0;
        case _Op.less:
          registers[a] = registers[b] < registers[c] ? 1 : 0;
        case _Op.lessEqual:
          registers[a] = registers[b] <= registers[c] ? 1 : 0;
        case _Op.greater:
          registers[a] = registers[b] > registers[c] ? 1 : 0;
        case _Op.greaterEqual:
          registers[a] = registers[b] >= registers[c] ? 1 : 0;
        case _Op.logicalNot:
          registers[a] = registers[b] == 0 ? 1 : 0;
        case _Op.minimum:
          final left = registers[b];
          final right = registers[c];
          registers[a] = left < right ? left : right;
        case _Op.maximum:
          final left = registers[b];
          final right = registers[c];
          registers[a] = left > right ? left : right;
        case _Op.jump:
          frame.pc = a;
        case _Op.jumpZero:
          if (registers[a] == 0) frame.pc = b;
        case _Op.jumpNonZero:
          if (registers[a] != 0) frame.pc = b;
        case _Op.jumpLessEqualZero:
          if (registers[a] <= 0) frame.pc = b;
        case _Op.switchDispatch:
          frame.pc = _switchTarget(module.switchSites[b], registers[a]);
        case _Op.decrement:
          registers[a] = registers[a] - 1;
        case _Op.call:
          if (stack.length >= limits.maxCallDepth) {
            throw ComputeVmRuntimeException(
              'maximum call depth ${limits.maxCallDepth} exceeded '
              'in ${frame.function.name}',
            );
          }
          final site = module.callSites[b];
          final callee = module.functions[site.functionId];
          if (callee.registerCount > limits.maxStackWords - stackWords) {
            throw ComputeVmRuntimeException(
              'maximum stack size ${limits.maxStackWords} words exceeded '
              'while calling ${callee.name}',
            );
          }
          final calleeRegisters = Int32List(callee.registerCount);
          for (var i = 0; i < site.argumentRegisters.length; i++) {
            calleeRegisters[i] = registers[site.argumentRegisters[i]];
          }
          stack.add(
            _VmFrame(
              function: callee,
              registers: calleeRegisters,
              returnRegister: a,
            ),
          );
          stackWords += callee.registerCount;
        case _Op.host:
          final site = module.hostSites[b];
          final name = module.hostNames[site.hostId];
          final callback = hosts[name];
          if (callback == null) {
            throw ComputeVmRuntimeException(
              'host function "$name" is no longer available',
            );
          }
          final arguments = List<int>.filled(site.argumentRegisters.length, 0);
          for (var i = 0; i < arguments.length; i++) {
            arguments[i] = registers[site.argumentRegisters[i]];
          }
          final result = callback(arguments);
          if (!_isSafeInteger(result)) {
            throw ComputeVmRuntimeException(
              'host function "$name" returned an integer outside the '
              'cross-platform safe range',
            );
          }
          registers[a] = result;
        case _Op.returnValue:
          final result = a < 0 ? 0 : registers[a];
          final completed = stack.removeLast();
          stackWords -= completed.registers.length;
          if (stack.isEmpty) return result;
          stack.last.registers[completed.returnRegister] = result;
        default:
          throw ComputeVmRuntimeException(
            'unknown bytecode opcode $opcode at ${frame.function.name}#$pc',
          );
      }
    }
    throw const ComputeVmRuntimeException('call stack ended without a result');
  }

  int _readByte(Uint8List buffer, int mask, int address) {
    if (mask >= 0) {
      return buffer[address & mask];
    }
    return address >= 0 && address < buffer.length ? buffer[address] : 0;
  }

  int _switchTarget(_VmSwitchSite site, int selector) {
    if (site.encoding == _VmSwitchEncoding.jumpTable) {
      final index = selector - site.minimumKey;
      return index >= 0 && index < site.targets.length
          ? site.targets[index]
          : site.defaultTarget;
    }
    if (site.encoding != _VmSwitchEncoding.binarySearch) {
      throw const ComputeVmRuntimeException('unresolved switch dispatch site');
    }

    var low = 0;
    var high = site.keys.length - 1;
    while (low <= high) {
      final middle = low + ((high - low) >> 1);
      final key = site.keys[middle];
      if (selector < key) {
        high = middle - 1;
      } else if (selector > key) {
        low = middle + 1;
      } else {
        return site.targets[middle];
      }
    }
    return site.defaultTarget;
  }

  void _writeByte(Uint8List buffer, int mask, int address, int value) {
    if (mask >= 0) {
      buffer[address & mask] = value;
      return;
    }
    if (address >= 0 && address < buffer.length) buffer[address] = value;
  }

  // Using 16-bit limbs keeps the low 32 bits deterministic on Dart's
  // JavaScript backends as well as on native 64-bit Dart runtimes.
  int _multiplyInt32(int left, int right) {
    final leftLow = left & 0xFFFF;
    final leftHigh = (left >> 16) & 0xFFFF;
    final rightLow = right & 0xFFFF;
    final rightHigh = (right >> 16) & 0xFFFF;
    final low = leftLow * rightLow;
    final cross = (leftHigh * rightLow + leftLow * rightHigh) & 0xFFFF;
    return (low + (cross << 16)).toSigned(32);
  }
}

final class _VmFrame {
  _VmFrame({
    required this.function,
    required this.registers,
    required this.returnRegister,
  });

  final _VmFunction function;
  final Int32List registers;
  final int returnRegister;
  int pc = 0;
}
