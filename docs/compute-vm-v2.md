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

A later C/C++ executor can consume the same verified bytecode on iOS, Android,
and desktop through one FFI call per whole compute function. Web can retain the
Dart executor and later add a Worker without changing JSON semantics.

| Target | Current backend | ABI |
| --- | --- | --- |
| iOS | Dart AOT | Compute 2 / i32-v2 |
| Android | Dart AOT | Compute 2 / i32-v2 |
| macOS/Windows/Linux | Dart AOT/JIT | Compute 2 / i32-v2 |
| Web | Dart JavaScript | Compute 2 / i32-v2 |

## AOT baseline

`tool/compute_vm_benchmark.dart` exercises a one-million-iteration loop with a
uniform 256-way opcode-style switch. On the development macOS host, an AOT
executable measured a median **17.3 million dispatch iterations/second**
(`57.7 ns/iteration`). The compiled function contained 1,300 instructions and
263 basic blocks; each runtime switch used one jump-table dispatch instruction.

This is a synthetic kernel measurement, not a claim that a complete NES already
runs at 60 FPS. The NES program, framebuffer handoff, APU path, and mobile
device profiling remain separate follow-up work.

## Validation

Before the runtime is enabled for published Apps, CI must cover:

- arithmetic and int32 overflow;
- buffer wrapping and checked bounds;
- branches, loops, switch, recursion, break/continue, and early return;
- host ordering and error behavior;
- budget and all configured resource limits;
- deterministic differential tests against a small reference evaluator;
- long-running AOT benchmarks on representative iOS and Android devices.
