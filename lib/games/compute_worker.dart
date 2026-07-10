/// Background-isolate host for a [ComputeProgram] (worker mode of the compute
/// bridge). A `compute` block opts in with `"worker": {...}`; ops are forwarded
/// to a long-lived isolate so heavy per-frame calls never block the UI thread.
///
/// Conditional export: real isolate on dart:io platforms, no-op stub on the
/// web (no isolates there — see docs/nesd-web-performance.md §5 lever 2).
/// Matches the platform-bridge convention of pcm_sink.dart / app_fs.dart.
library;

export 'compute_worker_stub.dart' if (dart.library.io) 'compute_worker_native.dart';
