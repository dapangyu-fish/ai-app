// Generic byte-array intrinsics (memset/memcpy/memlut/planar8): semantics,
// bounds clamping, overlap, flip, transparency, and budget charging.
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_application_1/json_ui/compute/compute_kernel.dart';

ComputeProgram _prog(List<dynamic> body, {Map<String, int>? bufs}) {
  return ComputeProgram.compile({
    'buffers': bufs ?? {'a': 32, 'b': 32, 'lut': 8},
    'functions': {
      'f': {'params': <String>[], 'body': [...body, ['ret', 0]]},
    },
  });
}

void main() {
  group('memset', () {
    test('fills range, masks value to byte', () {
      final p = _prog([
        ['memset', 'a', 2, 4, 0x1FF],
      ]);
      p.call('f');
      expect(p.u8['a']!.sublist(0, 8), [0, 0, 255, 255, 255, 255, 0, 0]);
    });
    test('clamps negative offset and overlong length', () {
      final p = _prog([
        ['memset', 'a', -2, 6, 7], // → fills [0,4)
        ['memset', 'b', 30, 100, 9], // → fills [30,32)
      ]);
      p.call('f');
      expect(p.u8['a']!.sublist(0, 6), [7, 7, 7, 7, 0, 0]);
      expect(p.u8['b']![29], 0);
      expect(p.u8['b']![30], 9);
      expect(p.u8['b']![31], 9);
    });
    test('zero/negative length is a no-op', () {
      final p = _prog([
        ['memset', 'a', 4, 0, 1],
        ['memset', 'a', 4, -3, 1],
      ]);
      p.call('f');
      expect(p.u8['a']!.every((v) => v == 0), isTrue);
    });
  });

  group('memcpy', () {
    test('copies between buffers with offsets', () {
      final p = _prog([
        ['memset', 'a', 0, 4, 5],
        ['memcpy', 'b', 10, 'a', 1, 3],
      ]);
      p.call('f');
      expect(p.u8['b']!.sublist(9, 14), [0, 5, 5, 5, 0]);
    });
    test('overlapping same-buffer copy uses memmove semantics', () {
      final p = _prog([
        ['memset', 'a', 0, 1, 1],
        ['memset', 'a', 1, 1, 2],
        ['memset', 'a', 2, 1, 3],
        ['memcpy', 'a', 1, 'a', 0, 3], // shift right by 1
      ]);
      p.call('f');
      expect(p.u8['a']!.sublist(0, 5), [1, 1, 2, 3, 0]);
    });
    test('clamps to both buffers', () {
      final p = _prog([
        ['memset', 'a', 0, 32, 4],
        ['memcpy', 'b', 30, 'a', 0, 100], // dst clamps to 2
      ]);
      p.call('f');
      expect(p.u8['b']![29], 0);
      expect(p.u8['b']![30], 4);
      expect(p.u8['b']![31], 4);
    });
  });

  group('memlut', () {
    test('maps through table with table offset', () {
      final p = _prog([
        // src a = [2,0,1], lut = [10,20,30] at offset 1 → dst b = [lut[1+2],lut[1+0],lut[1+1]]
        ['memset', 'a', 0, 1, 2],
        ['memset', 'a', 1, 1, 0],
        ['memset', 'a', 2, 1, 1],
        ['memset', 'lut', 1, 1, 10],
        ['memset', 'lut', 2, 1, 20],
        ['memset', 'lut', 3, 1, 30],
        ['memlut', 'b', 0, 'a', 0, 3, 'lut', 1],
      ]);
      p.call('f');
      expect(p.u8['b']!.sublist(0, 3), [30, 10, 20]);
    });
    test('out-of-range table index yields 0', () {
      final p = _prog([
        ['memset', 'a', 0, 2, 200], // lut only 8 long
        ['memset', 'b', 0, 2, 9],
        ['memlut', 'b', 0, 'a', 0, 2, 'lut', 0],
      ]);
      p.call('f');
      expect(p.u8['b']!.sublist(0, 2), [0, 0]);
    });
  });

  group('planar8', () {
    test('decodes MSB-first, or-merges opaque, keeps 0 transparent', () {
      // lo=0b10010001 hi=0b01010000 → px per bit: 1,2,0,3,0,0,0,1
      final p = _prog([
        ['planar8', 'a', 4, 0x91, 0x50, 0x0C, 0],
      ]);
      p.call('f');
      expect(p.u8['a']!.sublist(4, 12),
          [1 | 12, 2 | 12, 0, 3 | 12, 0, 0, 0, 1 | 12]);
    });
    test('flip reverses pixel order', () {
      final p = _prog([
        ['planar8', 'a', 0, 0x91, 0x50, 0, 0],
        ['planar8', 'b', 0, 0x91, 0x50, 0, 1],
      ]);
      p.call('f');
      expect(p.u8['b']!.sublist(0, 8),
          p.u8['a']!.sublist(0, 8).reversed.toList());
    });
    test('out-of-bounds row is dropped whole', () {
      final p = _prog([
        ['planar8', 'a', 30, 0xFF, 0xFF, 0, 0], // 30+8 > 32
        ['planar8', 'a', -1, 0xFF, 0xFF, 0, 0],
      ]);
      p.call('f');
      expect(p.u8['a']!.every((v) => v == 0), isTrue);
    });
  });

  test('intrinsics charge budget by length', () {
    final p = _prog([
      ['memset', 'a', 0, 32, 1],
    ]);
    expect(() => p.call('f', budget: 3), throwsA(isA<ComputeBudgetExceeded>()));
    expect(p.call('f', budget: 1000), 0);
  });
}
