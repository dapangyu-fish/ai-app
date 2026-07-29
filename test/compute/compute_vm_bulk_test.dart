import 'package:flutter_application_1/json_ui/compute/compute_vm.dart';
import 'package:flutter_test/flutter_test.dart';

ComputeVmProgram _program(
  List<dynamic> body, {
  Map<String, int> buffers = const <String, int>{'a': 32, 'b': 32, 'lut': 256},
  Map<String, dynamic> init = const <String, dynamic>{},
  ComputeVmLimits limits = const ComputeVmLimits(),
}) {
  return ComputeVmProgram.compile(<String, dynamic>{
    'version': 2,
    'buffers': buffers,
    'init': init,
    'functions': <String, dynamic>{
      'run': <String, dynamic>{'body': body},
    },
  }, limits: limits);
}

Matcher _compileErrorContaining(String text) {
  return isA<ComputeVmCompileException>().having(
    (error) => error.message,
    'message',
    contains(text),
  );
}

void main() {
  group('memset', () {
    test('fills a clamped range and narrows the value to u8', () {
      final program = _program(<dynamic>[
        <dynamic>['memset', 'a', 2, 4, 0x1ff],
        <dynamic>['memset', 'a', -2, 6, 7],
        <dynamic>['memset', 'b', 30, 100, 9],
      ]);

      program.call('run');

      expect(program.buffer('a').sublist(0, 8), <int>[
        7,
        7,
        7,
        7,
        255,
        255,
        0,
        0,
      ]);
      expect(program.buffer('b').sublist(29), <int>[0, 9, 9]);
    });

    test('zero, negative, and fully out-of-range work are no-ops', () {
      final program = _program(<dynamic>[
        <dynamic>['memset', 'a', 4, 0, 1],
        <dynamic>['memset', 'a', 4, -3, 1],
        <dynamic>['memset', 'a', 99, 4, 1],
      ]);

      program.call('run');

      expect(program.buffer('a').every((value) => value == 0), isTrue);
    });
  });

  group('memlut', () {
    test('maps through a table and maps an invalid table index to zero', () {
      final program = _program(
        <dynamic>[
          <dynamic>['memlut', 'b', 0, 'a', 0, 4, 'lut', 1],
        ],
        init: const <String, dynamic>{
          'a': <int>[2, 0, 1, 200],
          'lut': <int>[0, 10, 20, 30],
        },
      );

      program.call('run');

      expect(program.buffer('b').sublist(0, 4), <int>[30, 10, 20, 0]);
    });

    test('clamps negative and overlong source/destination ranges', () {
      final program = _program(
        <dynamic>[
          // Dropping the two out-of-range destination elements also advances
          // the source by two, so a[2..6) lands at b[0..4).
          <dynamic>['memlut', 'b', -2, 'a', 0, 6, 'lut', 0],
          <dynamic>['memlut', 'b', 30, 'a', 0, 100, 'lut', 0],
        ],
        init: <String, dynamic>{
          'a': List<int>.generate(32, (index) => index),
          'lut': List<int>.generate(256, (index) => 255 - index),
        },
      );

      program.call('run');

      expect(program.buffer('b').sublist(0, 4), <int>[253, 252, 251, 250]);
      expect(program.buffer('b').sublist(30), <int>[255, 254]);
    });
  });

  group('planar8', () {
    test(
      'decodes MSB-first, preserves transparency, and ORs opaque pixels',
      () {
        final program = _program(<dynamic>[
          <dynamic>['planar8', 'a', 4, 0x91, 0x50, 0x0c, 0],
        ]);

        program.call('run');

        expect(program.buffer('a').sublist(4, 12), <int>[
          1 | 12,
          2 | 12,
          0,
          3 | 12,
          0,
          0,
          0,
          1 | 12,
        ]);
      },
    );

    test('flip reverses the decoded row', () {
      final program = _program(<dynamic>[
        <dynamic>['planar8', 'a', 0, 0x91, 0x50, 0, 0],
        <dynamic>['planar8', 'b', 0, 0x91, 0x50, 0, 1],
      ]);

      program.call('run');

      expect(
        program.buffer('b').sublist(0, 8),
        program.buffer('a').sublist(0, 8).reversed,
      );
    });

    test('drops a row unless all eight output bytes are in bounds', () {
      final program = _program(<dynamic>[
        <dynamic>['planar8', 'a', 30, 0xff, 0xff, 0, 0],
        <dynamic>['planar8', 'a', -1, 0xff, 0xff, 0, 0],
      ]);

      program.call('run');

      expect(program.buffer('a').every((value) => value == 0), isTrue);
    });
  });

  group('bytecode and limits', () {
    test('each bulk operation occupies one fixed-width instruction', () {
      final memset = _program(<dynamic>[
        <dynamic>['memset', 'a', 0, 1, 2],
      ]);
      final memlut = _program(<dynamic>[
        <dynamic>['memlut', 'b', 0, 'a', 0, 1, 'lut', 0],
      ]);
      final planar8 = _program(<dynamic>[
        <dynamic>['planar8', 'a', 0, 0, 0, 0, 0],
      ]);

      // Literal expressions compile to one instruction each and every
      // function has one implicit return. The remaining single instruction is
      // the side-table-backed bulk dispatch.
      expect(memset.functionInfo('run')!.instructionCount, 5);
      expect(memlut.functionInfo('run')!.instructionCount, 6);
      expect(planar8.functionInfo('run')!.instructionCount, 7);
    });

    test('caps the bulk side table independently', () {
      expect(
        () => _program(<dynamic>[
          <dynamic>['memset', 'a', 0, 1, 1],
        ], limits: const ComputeVmLimits(maxBulkSites: 0)),
        throwsA(_compileErrorContaining('bulk sites')),
      );
    });
  });

  group('dynamic budget', () {
    test('memset reserves its whole dynamic charge before mutation', () {
      final program = _program(<dynamic>[
        <dynamic>['memset', 'a', 0, 16, 7],
      ]);

      expect(
        () => program.call('run', budget: 5),
        throwsA(
          isA<ComputeVmBudgetExceeded>()
              .having(
                (error) => error.executedInstructions,
                'executedInstructions',
                4,
              )
              .having((error) => error.instruction, 'instruction', 3),
        ),
      );
      expect(program.buffer('a').every((value) => value == 0), isTrue);
      expect(program.call('run', budget: 7), 0);
      expect(program.buffer('a').sublist(0, 16), everyElement(7));
    });

    test('memlut reserves its whole dynamic charge before mutation', () {
      final program = _program(
        <dynamic>[
          <dynamic>['memlut', 'b', 0, 'a', 0, 8, 'lut', 0],
        ],
        init: <String, dynamic>{
          'a': List<int>.generate(8, (index) => index),
          'lut': List<int>.generate(256, (index) => index + 1),
        },
      );

      expect(
        () => program.call('run', budget: 6),
        throwsA(isA<ComputeVmBudgetExceeded>()),
      );
      expect(program.buffer('b').every((value) => value == 0), isTrue);
      expect(program.call('run', budget: 8), 0);
      expect(program.buffer('b').sublist(0, 8), <int>[1, 2, 3, 4, 5, 6, 7, 8]);
    });

    test('planar8 reserves its row charge before mutation', () {
      final program = _program(<dynamic>[
        <dynamic>['planar8', 'a', 0, 0xff, 0, 0, 0],
      ]);

      expect(
        () => program.call('run', budget: 6),
        throwsA(isA<ComputeVmBudgetExceeded>()),
      );
      expect(program.buffer('a').every((value) => value == 0), isTrue);
      expect(program.call('run', budget: 8), 0);
      expect(program.buffer('a').sublist(0, 8), everyElement(1));
    });
  });
}
