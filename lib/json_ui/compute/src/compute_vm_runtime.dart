part of '../compute_vm.dart';

/// Compact dispatch loop for modules whose functions retain scalar bytecode.
///
/// Keep this loop physically separate from [_ComputeVmFusedRunner]. Adding
/// superinstruction cases to the same switch measurably changes AOT code
/// layout even when a module never executes those cases.
class _ComputeVmScalarRunner {
  _ComputeVmScalarRunner({
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
    final stack = <_VmContinuation>[];
    var function = entry;
    var code = function.code;
    var registers = entryRegisters;
    var pc = 0;

    while (true) {
      if (_remainingBudget == 0) {
        throw ComputeVmBudgetExceeded(
          budget: _initialBudget,
          executedInstructions: _initialBudget,
          function: function.name,
          instruction: pc,
        );
      }
      if (pc < 0 || pc >= function.physicalInstructionCount) {
        throw ComputeVmRuntimeException(
          'invalid instruction pointer ${function.name}#$pc',
        );
      }
      _remainingBudget--;
      final base = pc * _instructionWidth;
      final opcode = code[base];
      final a = code[base + 1];
      final b = code[base + 2];
      final c = code[base + 3];
      final instruction = pc;
      pc++;

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
        case _Op.memset:
          _runMemset(module.bulkSites[a], registers, function, instruction);
        case _Op.memlut:
          _runMemlut(module.bulkSites[a], registers, function, instruction);
        case _Op.planar8:
          _runPlanar8(module.bulkSites[a], registers, function, instruction);
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
          pc = a;
        case _Op.jumpZero:
          if (registers[a] == 0) pc = b;
        case _Op.jumpNonZero:
          if (registers[a] != 0) pc = b;
        case _Op.jumpLessEqualZero:
          if (registers[a] <= 0) pc = b;
        case _Op.switchDispatch:
          pc = _switchTarget(module.switchSites[b], registers[a]);
        case _Op.decrement:
          registers[a] = registers[a] - 1;
        case _Op.call:
          if (stack.length + 1 >= limits.maxCallDepth) {
            throw ComputeVmRuntimeException(
              'maximum call depth ${limits.maxCallDepth} exceeded '
              'in ${function.name}',
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
            _VmContinuation(
              callerFunction: function,
              callerRegisters: registers,
              callerPc: pc,
              returnRegister: a,
            ),
          );
          stackWords += callee.registerCount;
          function = callee;
          code = callee.code;
          registers = calleeRegisters;
          pc = 0;
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
          stackWords -= registers.length;
          if (stack.isEmpty) return result;
          final continuation = stack.removeLast();
          function = continuation.callerFunction;
          registers = continuation.callerRegisters;
          registers[continuation.returnRegister] = result;
          code = function.code;
          pc = continuation.callerPc;
        default:
          throw ComputeVmRuntimeException(
            'unknown bytecode opcode $opcode at '
            '${function.name}#$instruction',
          );
      }
    }
  }

  void _runMemset(
    _VmBulkSite site,
    Int32List registers,
    _VmFunction function,
    int pc,
  ) {
    final arguments = site.argumentRegisters;
    final destination = u8[site.destinationBufferId];
    var destinationOffset = registers[arguments[0]];
    var length = registers[arguments[1]];
    if (destinationOffset < 0) {
      length += destinationOffset;
      destinationOffset = 0;
    }
    final available = destination.length - destinationOffset;
    if (length > available) length = available;
    if (length <= 0) return;

    // The dispatch itself already consumed one instruction. Preserve the
    // original bulk cost of 1 + floor(length / 8) by reserving only the
    // length-dependent remainder here.
    _chargeBulkBudget(length >> 3, function, pc);
    destination.fillRange(
      destinationOffset,
      destinationOffset + length,
      registers[arguments[2]] & 0xFF,
    );
  }

  void _runMemlut(
    _VmBulkSite site,
    Int32List registers,
    _VmFunction function,
    int pc,
  ) {
    final arguments = site.argumentRegisters;
    final destination = u8[site.destinationBufferId];
    final source = u8[site.sourceBufferId];
    final lookup = u8[site.lookupBufferId];
    var destinationOffset = registers[arguments[0]];
    var sourceOffset = registers[arguments[1]];
    var length = registers[arguments[2]];
    final lookupOffset = registers[arguments[3]];

    if (destinationOffset < 0) {
      length += destinationOffset;
      sourceOffset -= destinationOffset;
      destinationOffset = 0;
    }
    if (sourceOffset < 0) {
      length += sourceOffset;
      destinationOffset -= sourceOffset;
      sourceOffset = 0;
    }
    final destinationAvailable = destination.length - destinationOffset;
    if (length > destinationAvailable) length = destinationAvailable;
    final sourceAvailable = source.length - sourceOffset;
    if (length > sourceAvailable) length = sourceAvailable;
    if (length <= 0) return;

    // Table mapping does more work per element than a fill, so one additional
    // budget unit covers each complete group of four mapped bytes.
    _chargeBulkBudget(length >> 2, function, pc);
    for (var index = 0; index < length; index++) {
      final lookupIndex = lookupOffset + source[sourceOffset + index];
      destination[destinationOffset +
          index] = lookupIndex >= 0 && lookupIndex < lookup.length
          ? lookup[lookupIndex]
          : 0;
    }
  }

  void _runPlanar8(
    _VmBulkSite site,
    Int32List registers,
    _VmFunction function,
    int pc,
  ) {
    final arguments = site.argumentRegisters;
    final destination = u8[site.destinationBufferId];
    final destinationOffset = registers[arguments[0]];
    if (destinationOffset < 0 || destinationOffset > destination.length - 8) {
      return;
    }

    // A valid planar row always handles exactly eight pixels. Together with
    // the dispatch unit, it costs two budget units.
    _chargeBulkBudget(1, function, pc);
    final lowPlane = registers[arguments[1]];
    final highPlane = registers[arguments[2]];
    final opaqueOr = registers[arguments[3]];
    final flipped = registers[arguments[4]] != 0;
    for (var pixelIndex = 0; pixelIndex < 8; pixelIndex++) {
      final bit = flipped ? pixelIndex : 7 - pixelIndex;
      final pixel = (((highPlane >> bit) & 1) << 1) | ((lowPlane >> bit) & 1);
      destination[destinationOffset + pixelIndex] = pixel == 0
          ? 0
          : (pixel | opaqueOr) & 0xFF;
    }
  }

  /// Reserve the length-dependent part of one bulk instruction before it
  /// mutates any buffer. A failed reservation leaves the destination intact.
  void _chargeBulkBudget(int additional, _VmFunction function, int pc) {
    if (additional <= _remainingBudget) {
      _remainingBudget -= additional;
      return;
    }
    throw ComputeVmBudgetExceeded(
      budget: _initialBudget,
      executedInstructions: _initialBudget - _remainingBudget,
      function: function.name,
      instruction: pc,
    );
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

/// Expanded dispatch loop used only when a module retained profitable
/// superinstructions. It also accepts scalar opcodes because optimized and
/// scalar functions may coexist in one module and call each other.
final class _ComputeVmFusedRunner extends _ComputeVmScalarRunner {
  _ComputeVmFusedRunner({
    required super.module,
    required super.u8,
    required super.u8Masks,
    required super.i32,
    required super.hosts,
    required super.limits,
    required super.budget,
  });

  @override
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
    final stack = <_VmContinuation>[];
    var function = entry;
    var code = function.dispatchCode!;
    var registers = entryRegisters;
    var pc = 0;

    while (true) {
      if (pc < 0 || pc >= function.physicalInstructionCount) {
        if (_remainingBudget == 0) {
          throw ComputeVmBudgetExceeded(
            budget: _initialBudget,
            executedInstructions: _initialBudget,
            function: function.name,
            instruction: pc,
          );
        }
        throw ComputeVmRuntimeException(
          'invalid instruction pointer ${function.name}#$pc',
        );
      }
      final base = pc * _instructionWidth;
      final dispatchHeader = code[base];
      _chargeOptimizedSpan(
        function,
        pc,
        dispatchHeader >> _packedDispatchOpcodeBits,
      );
      final opcode = dispatchHeader & _packedDispatchOpcodeMask;
      final a = code[base + 1];
      final b = code[base + 2];
      final c = code[base + 3];
      final instruction = pc;
      pc++;

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
        case _Op.memset:
          _runMemset(
            module.bulkSites[a],
            registers,
            function,
            function.logicalSourceStarts[instruction],
          );
        case _Op.memlut:
          _runMemlut(
            module.bulkSites[a],
            registers,
            function,
            function.logicalSourceStarts[instruction],
          );
        case _Op.planar8:
          _runPlanar8(
            module.bulkSites[a],
            registers,
            function,
            function.logicalSourceStarts[instruction],
          );
        case _Op.constantMove:
          registers[a] = b;
          pc++;
        case _Op.moveMove:
          registers[a] = registers[b];
          pc++;
        case _Op.loadU8Immediate:
          registers[a] = _readByte(u8[b], u8Masks[b], c);
          pc++;
        case _Op.loadI32Immediate:
          registers[a] = c >= 0 && c < i32[b].length ? i32[b][c] : 0;
          pc++;
        case _Op.loadU8ImmediateMove:
          registers[a] = _readByte(u8[b], u8Masks[b], c);
          pc += 2;
        case _Op.loadI32ImmediateMove:
          registers[a] = c >= 0 && c < i32[b].length ? i32[b][c] : 0;
          pc += 2;
        case _Op.binaryImmediateRight:
          registers[b] = _binaryResult(a, registers[b], c);
          pc++;
        case _Op.binaryImmediateDistinct:
          final opcodeMask = (1 << _packedBinaryOpcodeBits) - 1;
          final destination = a >> _packedBinaryOpcodeBits;
          registers[destination] = _binaryResult(
            a & opcodeMask,
            registers[b],
            c,
          );
          pc++;
        case _Op.constantFoldedBinary:
          registers[a] = b;
          pc += 2;
        case _Op.binaryRegisterRight:
          registers[b] = _binaryResult(a, registers[b], registers[c]);
          pc++;
        case _Op.returnImmediate:
          stackWords -= registers.length;
          if (stack.isEmpty) return a;
          final continuation = stack.removeLast();
          function = continuation.callerFunction;
          registers = continuation.callerRegisters;
          registers[continuation.returnRegister] = a;
          code = function.dispatchCode!;
          pc = continuation.callerPc;
        case _Op.storeU8ImmediateBoth:
          _writeByte(u8[a], u8Masks[a], b, c);
          pc += 2;
        case _Op.storeI32ImmediateBoth:
          if (b >= 0 && b < i32[a].length) i32[a][b] = c;
          pc += 2;
        case _Op.u8RmwImmediate:
          final opcodeMask = (1 << _packedBinaryOpcodeBits) - 1;
          final bufferId = a >> _packedBinaryOpcodeBits;
          final value = _readByte(u8[bufferId], u8Masks[bufferId], b);
          _writeByte(
            u8[bufferId],
            u8Masks[bufferId],
            b,
            _binaryResult(a & opcodeMask, value, c),
          );
          pc += 5;
        case _Op.i32RmwImmediate:
          final opcodeMask = (1 << _packedBinaryOpcodeBits) - 1;
          final bufferId = a >> _packedBinaryOpcodeBits;
          if (b >= 0 && b < i32[bufferId].length) {
            i32[bufferId][b] = _binaryResult(
              a & opcodeMask,
              i32[bufferId][b],
              c,
            );
          }
          pc += 5;
        case _Op.loadU8ImmediateBinaryImmediate:
          final binaryOpcode = a & _packedBinaryOpcodeMask;
          final bufferId = (a >> _packedBinaryOpcodeBits) & _packedBufferIdMask;
          final destination =
              (a >> (_packedBinaryOpcodeBits + _packedBufferIdBits)) &
              _packedRegisterMask;
          registers[destination] = _binaryResult(
            binaryOpcode,
            _readByte(u8[bufferId], u8Masks[bufferId], b),
            c,
          );
          pc += 3;
        case _Op.loadI32ImmediateBinaryImmediate:
          final binaryOpcode = a & _packedBinaryOpcodeMask;
          final bufferId = (a >> _packedBinaryOpcodeBits) & _packedBufferIdMask;
          final destination =
              (a >> (_packedBinaryOpcodeBits + _packedBufferIdBits)) &
              _packedRegisterMask;
          final value = b >= 0 && b < i32[bufferId].length
              ? i32[bufferId][b]
              : 0;
          registers[destination] = _binaryResult(binaryOpcode, value, c);
          pc += 3;
        case _Op.loadU8ImmediateCompareJumpZero:
          final comparisonOpcode = a & _packedBinaryOpcodeMask;
          final bufferId = a >> _packedBinaryOpcodeBits;
          final jumpBase = (instruction + 4) * _instructionWidth;
          if (_comparisonResult(
            comparisonOpcode,
            _readByte(u8[bufferId], u8Masks[bufferId], b),
            c,
          )) {
            pc += 4;
          } else {
            pc = code[jumpBase + 2];
          }
        case _Op.loadI32ImmediateCompareJumpZero:
          final comparisonOpcode = a & _packedBinaryOpcodeMask;
          final bufferId = a >> _packedBinaryOpcodeBits;
          final value = b >= 0 && b < i32[bufferId].length
              ? i32[bufferId][b]
              : 0;
          final jumpBase = (instruction + 4) * _instructionWidth;
          if (_comparisonResult(comparisonOpcode, value, c)) {
            pc += 4;
          } else {
            pc = code[jumpBase + 2];
          }
        case _Op.binaryImmediatePair:
          final destination = a >> (2 * _packedBinaryOpcodeBits);
          final firstOpcode =
              (a >> _packedBinaryOpcodeBits) & _packedBinaryOpcodeMask;
          final secondOpcode = a & _packedBinaryOpcodeMask;
          final firstResult = _binaryResult(
            firstOpcode,
            registers[destination],
            b,
          ).toSigned(32);
          registers[destination] = _binaryResult(secondOpcode, firstResult, c);
          pc += 3;
        case _Op.binaryImmediateDistinctPair:
          final firstBase = (instruction + 1) * _instructionWidth;
          final secondConstantBase = (instruction + 2) * _instructionWidth;
          final secondBase = (instruction + 3) * _instructionWidth;
          final firstDestination = code[firstBase + 1];
          final firstResult = _binaryResult(
            code[firstBase],
            registers[code[firstBase + 2]],
            a,
          ).toSigned(32);
          registers[firstDestination] = firstResult;
          registers[code[secondBase + 1]] = _binaryResult(
            code[secondBase],
            firstResult,
            module.constants[code[secondConstantBase + 2]],
          );
          pc += 3;
        case _Op.constantJumpZero:
          if (a == 0) {
            pc = b;
          } else {
            pc++;
          }
        case _Op.normalizeAndJump:
          registers[a] = registers[b] == 0 ? 0 : 1;
          pc = c;
        case _Op.compareImmediateJumpZero:
          final jumpBase = (instruction + 2) * _instructionWidth;
          if (_comparisonResult(a, registers[b], c)) {
            pc += 2;
          } else {
            pc = code[jumpBase + 2];
          }
        case _Op.moveCompareImmediateJumpZero:
          registers[a] = registers[b];
          final compareBase = (instruction + 1) * _instructionWidth;
          final jumpBase = (instruction + 3) * _instructionWidth;
          if (_comparisonResult(
            code[compareBase + 1],
            registers[code[compareBase + 2]],
            code[compareBase + 3],
          )) {
            pc += 3;
          } else {
            pc = code[jumpBase + 2];
          }
        case _Op.moveBinaryImmediateDistinctPair:
          registers[a] = registers[b];
          final pairBase = (instruction + 1) * _instructionWidth;
          final firstBase = (instruction + 2) * _instructionWidth;
          final secondConstantBase = (instruction + 3) * _instructionWidth;
          final secondBase = (instruction + 4) * _instructionWidth;
          final firstDestination = code[firstBase + 1];
          final firstResult = _binaryResult(
            code[firstBase],
            registers[code[firstBase + 2]],
            code[pairBase + 1],
          ).toSigned(32);
          registers[firstDestination] = firstResult;
          registers[code[secondBase + 1]] = _binaryResult(
            code[secondBase],
            firstResult,
            module.constants[code[secondConstantBase + 2]],
          );
          pc += 4;
        case _Op.compareMovedRegisterJumpZero:
          final jumpBase = (instruction + 2) * _instructionWidth;
          if (_comparisonResult(a, registers[b], registers[c])) {
            pc += 2;
          } else {
            pc = code[jumpBase + 2];
          }
        case _Op.compareRegisterJumpZero:
          final jumpBase = (instruction + 1) * _instructionWidth;
          if (_comparisonResult(a, registers[b], registers[c])) {
            pc++;
          } else {
            pc = code[jumpBase + 2];
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
          pc = a;
        case _Op.jumpZero:
          if (registers[a] == 0) pc = b;
        case _Op.jumpNonZero:
          if (registers[a] != 0) pc = b;
        case _Op.jumpLessEqualZero:
          if (registers[a] <= 0) pc = b;
        case _Op.switchDispatch:
          pc = _switchTarget(module.switchSites[b], registers[a]);
        case _Op.decrement:
          registers[a] = registers[a] - 1;
        case _Op.call:
          if (stack.length + 1 >= limits.maxCallDepth) {
            throw ComputeVmRuntimeException(
              'maximum call depth ${limits.maxCallDepth} exceeded '
              'in ${function.name}',
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
            _VmContinuation(
              callerFunction: function,
              callerRegisters: registers,
              callerPc: pc,
              returnRegister: a,
            ),
          );
          stackWords += callee.registerCount;
          function = callee;
          code = callee.dispatchCode!;
          registers = calleeRegisters;
          pc = 0;
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
          stackWords -= registers.length;
          if (stack.isEmpty) return result;
          final continuation = stack.removeLast();
          function = continuation.callerFunction;
          registers = continuation.callerRegisters;
          registers[continuation.returnRegister] = result;
          code = function.dispatchCode!;
          pc = continuation.callerPc;
        default:
          throw ComputeVmRuntimeException(
            'unknown bytecode opcode $opcode at '
            '${function.name}#'
            '${function.logicalSourceStarts[instruction]}',
          );
      }
    }
  }

  @pragma('vm:prefer-inline')
  void _chargeOptimizedSpan(
    _VmFunction function,
    int physicalInstruction,
    int logicalCost,
  ) {
    if (logicalCost <= _remainingBudget) {
      _remainingBudget -= logicalCost;
      return;
    }
    final failedInstruction =
        function.logicalSourceStarts[physicalInstruction] + _remainingBudget;
    throw ComputeVmBudgetExceeded(
      budget: _initialBudget,
      executedInstructions: _initialBudget,
      function: function.name,
      instruction: failedInstruction,
    );
  }

  @pragma('vm:prefer-inline')
  int _binaryResult(int opcode, int left, int right) {
    return switch (opcode) {
      _Op.add => left + right,
      _Op.subtract => left - right,
      _Op.multiply => _multiplyInt32(left, right),
      _Op.divide => right == 0 ? 0 : left ~/ right,
      _Op.modulo => right == 0 ? 0 : left % right,
      _Op.bitAnd => left & right,
      _Op.bitOr => left | right,
      _Op.bitXor => left ^ right,
      _Op.shiftLeft => left << (right & 31),
      _Op.shiftRight => (left & 0xFFFFFFFF) >> (right & 31),
      _Op.equal => left == right ? 1 : 0,
      _Op.notEqual => left != right ? 1 : 0,
      _Op.less => left < right ? 1 : 0,
      _Op.lessEqual => left <= right ? 1 : 0,
      _Op.greater => left > right ? 1 : 0,
      _Op.greaterEqual => left >= right ? 1 : 0,
      _Op.minimum => left < right ? left : right,
      _Op.maximum => left > right ? left : right,
      _ => throw ComputeVmRuntimeException(
        'invalid fused binary opcode $opcode',
      ),
    };
  }

  @pragma('vm:prefer-inline')
  bool _comparisonResult(int opcode, int left, int right) {
    return switch (opcode) {
      _Op.equal => left == right,
      _Op.notEqual => left != right,
      _Op.less => left < right,
      _Op.lessEqual => left <= right,
      _Op.greater => left > right,
      _Op.greaterEqual => left >= right,
      _ => throw ComputeVmRuntimeException(
        'invalid fused comparison opcode $opcode',
      ),
    };
  }
}

final class _VmContinuation {
  _VmContinuation({
    required this.callerFunction,
    required this.callerRegisters,
    required this.callerPc,
    required this.returnRegister,
  });

  final _VmFunction callerFunction;
  final Int32List callerRegisters;
  final int callerPc;
  final int returnRegister;
}
