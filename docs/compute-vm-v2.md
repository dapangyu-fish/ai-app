# Compute VM v2

## Scope

Compute VM v2 is a general-purpose, deterministic integer compute module for
JSON Apps. It is not an NES-specific runtime. Emulator CPU/PPU/APU behavior,
image algorithms, path finding, procedural generation, and other workloads are
program data executed by the same VM.

The first implementation is based directly on `main`. It does not import the
experimental NES implementation from `perf/nesd-native`.

## JSON module

```json
{
  "dsl": "4.0",
  "compute": {
    "engine": {
      "abi": 2,
      "backend": "vm",
      "semantics": "i32-v2"
    },
    "program": {
      "version": 2,
      "buffers": {"bytes": 256},
      "i32": {"words": 16},
      "init": {
        "bytes": [1, 2, 3],
        "words": [4, 5, 6]
      },
      "functions": {
        "sum": {
          "params": ["n"],
          "body": [
            ["set", "i", 0],
            ["set", "value", 0],
            ["while", ["<", ["var", "i"], ["var", "n"]], [
              ["set", "value", ["+", ["var", "value"], ["var", "i"]]],
              ["set", "i", ["+", ["var", "i"], 1]]
            ]],
            ["ret", ["var", "value"]]
          ]
        }
      }
    }
  }
}
```

The module owns its typed buffers. Buffer state survives function calls; local
registers and the call stack do not.

`compute` is a top-level App capability. It requires DSL 4.x so clients that
only implement DSL 3 reject the App instead of silently ignoring compute
actions.

## Execution model

The compiler resolves names to integer IDs, lowers structured control flow to
basic blocks, and emits fixed-width four-word register bytecode. Runtime
execution does not walk JSON and does not invoke a Dart closure per expression.
Dense switches, including a 256-opcode CPU dispatch, use a single dispatch
instruction and jump table. Sparse switches use one dispatch instruction plus
a binary-search side table.

Before execution, the compiler builds a compact integer IR and applies only
generic, side-effect-safe rewrites: input/output copy propagation,
destination-aware immediate operations, constant folding, and target-safe
superinstruction fusion. Redundant physical slots may be removed, while a
logical source/cost map retains the original scalar instruction address space.
Jump/switch behavior, instruction limits, budget accounting, and reported
failure PCs therefore remain compatible with `optimize: false`. An optimized
operation reserves its complete logical cost before a buffer write, host call,
or return becomes visible.

Fusion is adaptive rather than mandatory:

- a function keeps scalar bytecode unless static dispatches fall by at least
  25%;
- a switch with 16 or more alternatives must additionally save at least four
  dispatches per mutually exclusive alternative, preventing a large set of
  cold arms from overstating hot-path benefit;
- `ComputeVmProgram.compile(..., optimize: false)` provides an explicit scalar
  compatibility/reference mode;
- scalar and fused bytecode use physically separate interpreter loops;
- runner selection is per public entry point, including its statically
  reachable callees, so an unrelated optimized helper cannot slow a scalar
  hot path.

All values use signed 32-bit two's-complement semantics. Byte buffers store the
low eight bits. A non-empty power-of-two byte buffer wraps addresses; other
buffers use checked access (out-of-range reads return zero and writes are
ignored). Word-buffer indices are always checked.

Every bytecode instruction consumes budget. The budget is shared by nested
calls. This cost model is part of Compute ABI 2; a future incompatible lowering
must use a new ABI. The VM incrementally enforces limits for AST size/depth,
name length, buffer count/memory, function and instruction count, register
count, switch tables, call depth, total stack words, and per-call budget.
The production defaults cap all typed buffers together at 16 MiB, one
synchronous transfer at 1,048,576 elements, and one call at 5,000,000
instructions. Inline JSON initializers are capped at 262,144 elements; larger
byte payloads should use chunked `@compute.load`. Trusted native callers can
pass a stricter or more permissive `ComputeVmLimits`; published JSON Apps
cannot raise these client ceilings.

Numeric inputs are restricted to JavaScript's safe integer range and are then
normalized to signed int32. This keeps Native and Web behavior deterministic.
u8 and i32 buffers cannot share a name, and initializers cannot be longer than
their target buffer. ABI `version` must have the numeric value `2`; `2` and
`2.0` are intentionally equivalent because Dart Web represents both JSON
numbers identically.

## JSON App actions

The ordinary JSON interpreter and Flame game logic expose the same generic
actions:

```json
{"call":"@compute.call","args":{"function":"sum","args":[100],"budget":100000},"assign":"global.result"}
{"call":"@compute.read","args":{"kind":"u8","buffer":"ram","offset":0,"length":16},"assign":"global.bytes"}
{"call":"@compute.write","args":{"kind":"i32","buffer":"input","offset":0,"values":[1,2,3]}}
{"call":"@compute.load","args":{"buffer":"rom","offset":0,"base64":"AAECAw=="}}
{"call":"@compute.reset"}
```

- `call` is synchronous and returns one int32.
- `read` returns one integer or a bounded list.
- `write` accepts one value or a bounded list and validates the whole transfer
  before mutating VM state.
- `load` decodes base64 into a u8 buffer.
- `reset` zeroes each buffer and restores compact copies of only its declared
  initializer prefixes, even if the caller later mutates its original
  configuration object.

The `@compute.*` namespace is routed before dependency calls. Nested Apps save
and restore their own Compute session. A mounted `flame_game` receives the
current App session, so its frame/tick/input logic can call the same API without
adding NES-specific actions to the framework.

## Compatibility and rollout

- Existing JSON Apps that do not declare `compute` are unaffected.
- Existing Compute VM bytecode semantics and budgets are unchanged by
  superinstruction fusion; optimization can be disabled without changing JSON.
- DSL 3.3 remains accepted for Apps without Compute; Compute Apps declare 4.0.
- The public runtime exposes compute through an App-scoped session/action
  facade rather than through game-specific classes.
- Synchronous `call` and asynchronous worker `submit` are different contracts
  and must not be selected implicitly by a backend.
- A client must verify any server-precompiled artifact and compare its source
  hash. The JSON program remains the source of truth and fallback.
- Apps that require Compute ABI 2 must be gated from older clients through a
  DSL major-version or Registry feature negotiation before production rollout.

## Platform direction

The bytecode and module ABI are backend-independent. The current executor is
pure Dart: Flutter compiles it AOT on iOS, Android, and desktop, while Web uses
the Dart JavaScript backend. It does not depend on WASM and contains no
platform-specific emulator code.

The current optimization path stays in the shared Dart executor; it does not
require C/C++, Rust, FFI, WASM, or an emulator-specific backend. A different
backend could implement the same verified ABI in the future, but that is not a
dependency of this design or rollout.

| Target | Current backend | ABI |
| --- | --- | --- |
| iOS | Dart AOT | Compute 2 / i32-v2 |
| Android | Dart AOT | Compute 2 / i32-v2 |
| macOS/Windows/Linux | Dart AOT/JIT | Compute 2 / i32-v2 |
| Web | Dart JavaScript | Compute 2 / i32-v2 |

## AOT baseline

`tool/compute_vm_benchmark.dart` compares `optimize: false` with the adaptive
compiler in the same AOT executable. It includes two generic workloads:

- A uniform 256-way opcode-style switch contains 1,300 logical instructions
  and 263 basic blocks. The optimizer rejects its low static payoff and
  leaves the entry on the scalar loop. On the development macOS host, repeated
  runs stayed within roughly 1% of the forced-scalar result at about **20
  million iterations/second**.
- A dense arithmetic/byte-buffer loop reduces eight dispatches across 20
  logical instructions. It measured about **40.9 million iterations/second**,
  versus about **24.0 million** in forced-scalar mode: roughly a **1.70x**
  speedup. The preceding optimizer measured about 32.3 million
  iterations/second on the same host.

An additional compatibility benchmark used the same extracted NES JSON
program, ROM, warm-up, and benchmark-only graphics helper on both revisions.
Across three separate AOT processes (70 warm-up frames and 240 measured frames
per process), median-of-medians frame time fell from **37.866 ms** to
**35.354 ms** (**6.63%**). CPU results, frame count, framebuffer checksum, and
all u8/i32 buffer state matched. Load-time optimized compilation rose from
about **9.0 ms** to **16.7 ms** once per App, paying back after roughly three
emulated frames in this workload.

The measurement host was an Apple M4 Pro MacBook Pro running macOS 26.5.2 and
Dart 3.11.5 AOT. Per-process baseline medians were 37.866, 37.824, and 37.904
ms; optimized medians were 35.333, 35.354, and 35.370 ms. The ROM SHA-256 was
`24710e359c3bf74d3e0f9b5b847507183a73188393415d546aa610f87faaf36b`;
the extracted JSON SHA-256 was
`eda786b35d0b325c1abdfe8d9265c6d4da16bc36374cbdd75cb0d3032a3bdf9f`.
The graphics helper was identical in both disposable benchmark copies and is
not part of the production optimizer.

These results are evidence for interpreter-layer improvement, not a claim that
the complete App already reaches 60 FPS. Framebuffer handoff, audio, Flutter
frame scheduling, and physical iOS/Android profiling remain separate work.

## Validation

Before the runtime is enabled for published Apps, CI must cover:

- arithmetic and int32 overflow;
- buffer wrapping and checked bounds;
- branches, loops, switch, recursion, break/continue, and early return;
- host ordering and error behavior;
- budget and all configured resource limits;
- deterministic differential tests against a small reference evaluator;
- long-running AOT benchmarks on representative iOS and Android devices.
