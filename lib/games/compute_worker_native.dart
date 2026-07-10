/// Native compute worker: runs a [ComputeProgram] on a dedicated isolate.
///
/// Protocol (all messages are plain maps, main → worker):
///   {op:'load',  buf, bytes, offset, mirror}   load bytes into a byte buffer
///   {op:'setu8', buf, addr, v}                 single byte poke
///   {op:'input', i, v}                         host input word (controller)
///   {op:'call',  id, fn, args, budget, mirror:[names]}  run a function
///   {op:'audio', id, drain, buf}               drain int16 PCM samples
///   {op:'quit'}
/// worker → main:
///   {ev:'ready', port}                         handshake
///   {ev:'done',  id, fn, ret, mirrors:{name: Uint8List}}
///   {ev:'samples', id, data: Int16List}
///
/// The worker compiles the SAME program spec as the main-side shadow copy, so
/// buffer layout and `init` tables match; mirrored buffers are copied back
/// after every call (a 256×240 framebuffer is ~61KB — trivial per frame).
library;

import 'dart:isolate';
import 'dart:typed_data';

import '../json_ui/compute/compute_kernel.dart';

class ComputeWorker {
  ComputeWorker._(this._isolate, this._port, this._events);

  static bool get supported => true;

  final Isolate _isolate;
  final SendPort _port;
  final ReceivePort _events;

  static Future<ComputeWorker?> spawn({
    required Map<String, dynamic> programSpec,
    required void Function(Map<dynamic, dynamic> event) onEvent,
  }) async {
    final events = ReceivePort();
    final Isolate iso;
    try {
      iso = await Isolate.spawn(
        _workerMain,
        [programSpec, events.sendPort],
        debugName: 'compute-worker',
      );
    } catch (_) {
      events.close();
      return null; // platform without isolate support → sync fallback
    }
    // First message is the handshake carrying the worker's SendPort.
    SendPort? port;
    late final ComputeWorker worker;
    events.listen((msg) {
      if (msg is Map && msg['ev'] == 'ready') {
        port = msg['port'] as SendPort;
        return;
      }
      if (msg is Map) onEvent(msg);
    });
    // Wait for the handshake (bounded, isolate spawn already succeeded).
    while (port == null) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    worker = ComputeWorker._(iso, port!, events);
    return worker;
  }

  void post(Map<String, Object?> op) => _port.send(op);

  void dispose() {
    _port.send(const {'op': 'quit'});
    _events.close();
    _isolate.kill(priority: Isolate.beforeNextEvent);
  }
}

void _workerMain(List<dynamic> init) {
  final spec = (init[0] as Map).cast<String, dynamic>();
  final reply = init[1] as SendPort;
  // Same host bindings as GameCompute.fromSpec, backed by worker-local state
  // updated through {op:'input'} messages.
  final inputs = Int32List(8);
  final program = ComputeProgram.compile(spec, hosts: <String, HostFn>{
    'input': (args) {
      final i = args.isNotEmpty ? args[0] : 0;
      return (i >= 0 && i < inputs.length) ? inputs[i] : 0;
    },
  });
  final inbox = ReceivePort();
  reply.send({'ev': 'ready', 'port': inbox.sendPort});

  inbox.listen((msg) {
    if (msg is! Map) return;
    switch (msg['op']) {
      case 'load':
        final buf = program.u8[msg['buf']];
        final bytes = msg['bytes'] as Uint8List;
        final offset = (msg['offset'] as int?) ?? 0;
        if (buf == null) return;
        final n = bytes.length;
        for (var i = 0; i < n && offset + i < buf.length; i++) {
          buf[offset + i] = bytes[i];
        }
        if ((msg['mirror'] as bool? ?? false) &&
            offset == 0 && n > 0 && n * 2 <= buf.length) {
          for (var i = 0; i < n; i++) {
            buf[n + i] = bytes[i];
          }
        }
      case 'setu8':
        final buf = program.u8[msg['buf']];
        final addr = msg['addr'] as int;
        if (buf != null && addr >= 0 && addr < buf.length) {
          buf[addr] = (msg['v'] as int) & 0xFF;
        }
      case 'input':
        final i = msg['i'] as int;
        if (i >= 0 && i < inputs.length) inputs[i] = msg['v'] as int;
      case 'call':
        final fn = msg['fn'] as String;
        var ret = 0;
        try {
          ret = program.call(fn,
              args: (msg['args'] as List).cast<int>(),
              budget: msg['budget'] as int);
        } catch (_) {
          ret = 0; // mirror GameCompute.call's swallow-and-log contract
        }
        final mirrors = <String, Uint8List>{};
        for (final name in (msg['mirror'] as List).cast<String>()) {
          final b = program.u8[name];
          if (b != null) mirrors[name] = Uint8List.fromList(b);
        }
        reply.send(
            {'ev': 'done', 'id': msg['id'], 'fn': fn, 'ret': ret, 'mirrors': mirrors});
      case 'audio':
        final drain = msg['drain'] as String;
        var n = 0;
        if (program.hasFunction(drain)) {
          try {
            n = program.call(drain, args: const []);
          } catch (_) {}
        }
        final bytes = program.u8[msg['buf']];
        Int16List out;
        if (bytes == null || n <= 0) {
          out = Int16List(0);
        } else {
          final count = n * 2 <= bytes.length ? n : bytes.length ~/ 2;
          out = Int16List(count);
          for (var i = 0; i < count; i++) {
            final v = bytes[i * 2] | (bytes[i * 2 + 1] << 8);
            out[i] = v >= 0x8000 ? v - 0x10000 : v;
          }
        }
        reply.send({'ev': 'samples', 'id': msg['id'], 'data': out});
      case 'quit':
        inbox.close();
    }
  });
}
