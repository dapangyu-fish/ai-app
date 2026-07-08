// Standalone kernel validation + throughput benchmark.
// Run:  dart run kernel_test.dart
import 'dart:typed_data';
import 'package:myapp/json_ui/compute/compute_kernel.dart';

int _pass = 0, _fail = 0;
void expect(dynamic got, dynamic want, String label) {
  if (got == want) {
    _pass++;
  } else {
    _fail++;
    print('  FAIL $label: got $got want $want');
  }
}

void main() {
  // ---- 1. arithmetic, locals, control flow, functions ----
  final p1 = ComputeProgram.compile({
    'functions': {
      // sum 1..n via while
      'sum': {
        'params': ['n'],
        'body': [
          ['set', 'acc', 0],
          ['set', 'i', 1],
          ['while', ['<=', ['var', 'i'], ['var', 'n']], [
            ['set', 'acc', ['+', ['var', 'acc'], ['var', 'i']]],
            ['set', 'i', ['+', ['var', 'i'], 1]],
          ]],
          ['ret', ['var', 'acc']],
        ],
      },
      // recursive factorial (tests call + frame stack)
      'fact': {
        'params': ['n'],
        'body': [
          ['if', ['<=', ['var', 'n'], 1], [['ret', 1]]],
          ['ret', ['*', ['var', 'n'], ['call', 'fact', [['-', ['var', 'n'], 1]]]]],
        ],
      },
      // bitwise + switch dispatch
      'classify': {
        'params': ['x'],
        'body': [
          ['switch', ['&', ['var', 'x'], 3],
            [[0, [['ret', 100]]], [1, [['ret', 101]]], [2, [['ret', 102]]]],
            [['ret', 103]]],
        ],
      },
    },
  });
  expect(p1.call('sum', args: [100]), 5050, 'sum 1..100');
  expect(p1.call('fact', args: [10]), 3628800, 'fact 10');
  expect(p1.call('classify', args: [8]), 100, 'switch &3==0');
  expect(p1.call('classify', args: [7]), 103, 'switch default');

  // ---- 2. a REAL 6502 slice on byte-buffer RAM with opcode switch-dispatch ----
  // Program in RAM @ 0: LDA #$05; loop: STA $10; ADC #$01; INX; CPX #$04; BNE loop; BRK
  // Encoded: A9 05  85 10  69 01  E8  E0 04  D0 F7  00
  final prog6502 = [0xA9, 0x05, 0x85, 0x10, 0x69, 0x01, 0xE8, 0xE0, 0x04, 0xD0, 0xF7, 0x00];
  final ines = <String, dynamic>{
    'buffers': {'ram': 2048},
    'i32': {'reg': 8}, // 0=A 1=X 2=Y 3=PC 4=P(carry bit0) 5=zero 6=halt 7=steps
    'functions': {
      'reset': {
        'params': [],
        'body': [
          ['seti32', 'reg', 3, 0], // PC=0
          ['seti32', 'reg', 0, 0], ['seti32', 'reg', 1, 0], ['seti32', 'reg', 4, 0],
          ['seti32', 'reg', 6, 0], ['seti32', 'reg', 7, 0],
        ],
      },
      'run': {
        'params': ['maxSteps'],
        'body': [
          ['while', ['and', ['==', ['i32', 'reg', 6], 0],
                            ['<', ['i32', 'reg', 7], ['var', 'maxSteps']]], [
            ['set', 'pc', ['i32', 'reg', 3]],
            ['set', 'op', ['u8', 'ram', ['var', 'pc']]],
            ['seti32', 'reg', 7, ['+', ['i32', 'reg', 7], 1]],
            ['switch', ['var', 'op'], [
              [0xA9, [ // LDA #imm
                ['seti32', 'reg', 0, ['u8', 'ram', ['+', ['var', 'pc'], 1]]],
                ['seti32', 'reg', 5, ['==', ['i32', 'reg', 0], 0]],
                ['seti32', 'reg', 3, ['+', ['var', 'pc'], 2]],
              ]],
              [0x85, [ // STA zp
                ['setu8', 'ram', ['u8', 'ram', ['+', ['var', 'pc'], 1]], ['i32', 'reg', 0]],
                ['seti32', 'reg', 3, ['+', ['var', 'pc'], 2]],
              ]],
              [0x69, [ // ADC #imm
                ['set', 't', ['+', ['+', ['i32', 'reg', 0], ['u8', 'ram', ['+', ['var', 'pc'], 1]]], ['i32', 'reg', 4]]],
                ['seti32', 'reg', 4, ['>', ['var', 't'], 255]],
                ['seti32', 'reg', 0, ['&', ['var', 't'], 255]],
                ['seti32', 'reg', 3, ['+', ['var', 'pc'], 2]],
              ]],
              [0xE8, [ // INX
                ['seti32', 'reg', 1, ['&', ['+', ['i32', 'reg', 1], 1], 255]],
                ['seti32', 'reg', 3, ['+', ['var', 'pc'], 1]],
              ]],
              [0xE0, [ // CPX #imm -> set zero if equal
                ['seti32', 'reg', 5, ['==', ['i32', 'reg', 1], ['u8', 'ram', ['+', ['var', 'pc'], 1]]]],
                ['seti32', 'reg', 3, ['+', ['var', 'pc'], 2]],
              ]],
              [0xD0, [ // BNE rel (signed 8-bit)
                ['if', ['==', ['i32', 'reg', 5], 0], [
                  ['set', 'r', ['u8', 'ram', ['+', ['var', 'pc'], 1]]],
                  ['if', ['>', ['var', 'r'], 127], [['set', 'r', ['-', ['var', 'r'], 256]]]],
                  ['seti32', 'reg', 3, ['+', ['+', ['var', 'pc'], 2], ['var', 'r']]],
                ], [
                  ['seti32', 'reg', 3, ['+', ['var', 'pc'], 2]],
                ]],
              ]],
              [0x00, [ // BRK -> halt
                ['seti32', 'reg', 6, 1],
              ]],
            ], [ // default: halt on unknown
              ['seti32', 'reg', 6, 1],
            ]],
          ]],
          ['ret', ['i32', 'reg', 7]],
        ],
      },
    },
  };
  final cpu = ComputeProgram.compile(ines);
  cpu.buffer('ram').setRange(0, prog6502.length, prog6502);
  cpu.call('reset');
  final steps = cpu.call('run', args: [1000]);
  // Expect: A starts 5, +1 each of 4 loop iters -> A=9; X=4; RAM[$10]=last STA before final ADC.
  final regs = cpu.words('reg');
  expect(regs[1], 4, '6502 X==4 (loop count)');
  expect(regs[0], 9, '6502 A==9 (5+1*4)');
  expect(cpu.buffer('ram')[0x10], 8, '6502 RAM[\$10]==8');
  print('  6502 slice halted after $steps instructions, A=${regs[0]} X=${regs[1]} RAM10=${cpu.buffer('ram')[0x10]}');

  // ---- 3. throughput benchmark: tight ALU loop, measure million-ops/s ----
  final bench = ComputeProgram.compile({
    'functions': {
      'spin': {
        'params': ['iters'],
        'body': [
          ['set', 'a', 1], ['set', 'i', 0],
          ['while', ['<', ['var', 'i'], ['var', 'iters']], [
            // ~8 primitive ops per iter: mask, add, xor, shift
            ['set', 'a', ['&', ['+', ['^', ['var', 'a'], 13], 1], 0xFFFF]],
            ['set', 'a', ['|', ['<<', ['var', 'a'], 1], ['>>', ['var', 'a'], 3]]],
            ['set', 'i', ['+', ['var', 'i'], 1]],
          ]],
          ['ret', ['var', 'a']],
        ],
      },
    },
  });
  const iters = 20000000;
  final sw = Stopwatch()..start();
  final r = bench.call('spin', args: [iters], budget: iters + 100);
  sw.stop();
  final loopsPerSec = iters / (sw.elapsedMicroseconds / 1e6);
  final primPerSec = loopsPerSec * 8; // ~8 primitive ops per loop body
  print('  bench: $iters loops in ${sw.elapsedMilliseconds}ms  '
      '-> ${(loopsPerSec / 1e6).toStringAsFixed(1)}M loops/s  '
      '~${(primPerSec / 1e6).toStringAsFixed(0)}M prim-ops/s  (result=$r)');

  print('\n=== $_pass passed, $_fail failed ===');
  // NES needs ~1e8 prim-ops/s for realtime; jsonlogic baseline was ~0.06M.
}
