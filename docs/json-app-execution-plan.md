# JSON App execution plans

## Goal

JSON remains the portable source format. On first use, the client converts
repeated syntax into an immutable, value-independent plan and reuses it while
the cache entry remains resident. It executes that plan against the current App
state. This removes repeated parsing and tree traversal without adding an
NES-specific executor or a native extension.

Plans are deterministic runtime infrastructure. They are built by ordinary
Dart code and do not require AI participation, server-side compilation, or a
platform-specific backend.

The full App plan is compiled after each dynamic `loadConfig`, not when the
Flutter binary is built. A different JSON source receives a different SHA-256
and plan; nested Apps retain and restore their own plan. The client currently
emits AppExecutionPlan ABI 1 with:

- a constant/value tree and source paths;
- pre-parsed templates and variable namespaces;
- a global state symbol table with stable integer slots and inferred initial
  value kinds;
- Action, Widget, and Screen structural plans;
- an immutable source hash and diagnostic counts.

Only syntax and source structure are retained. Plans never capture state
values, BuildContext, a dependency module, or a Compute session.

## PathPlan

The first general plan covers dot paths used by variables and templates.
Previously, a successful global lookup split the same path and traversed the
same Map/List chain twice: first to distinguish a missing value from a stored
`null`, then to fetch the value. `PathPlan` now:

- splits a path once and pre-parses possible List indexes;
- performs one lookup that returns both `found` and `value`;
- retains neither the root object nor a fetched value, so later mutations are
  always visible;
- preserves numeric Map keys, List bounds, missing/null distinction, and the
  existing nested-write behavior;
- uses an App-scoped, insertion-ordered cache capped at 512 paths;
- clears the cache on App replacement and nested-App restoration.

Template, full-expression, i18n-call, and locale-separator regular expressions
are also compiled once per Dart isolate instead of once per resolution.

TemplatePlan is now used by `resolveTemplate` and `resolveExpression`.
Value/Action plans are also used for source-owned expression trees and action
arguments. Runtime-generated values use bounded dynamic caches or the legacy
resolver. `@get_app_config` deliberately disables identity-bound structural
fast paths for that App because the DSL receives the live Map and may mutate
it; String-keyed TemplatePlans remain valid.

## Objective AOT result

`tool/json_app_plan_benchmark.dart` compares the old split plus
`has/get` traversal with the planned single traversal. Its eight-path workload
includes nested Maps, Lists, numeric Map keys, stored null, early and middle
misses, an out-of-range index, and a scalar intermediate.

Three separate macOS AOT processes on an Apple M4 Pro MacBook Pro (macOS
26.5.2, Dart 3.11.5), each using five alternating samples of 8,000,000 lookups,
measured:

| Process | Legacy lookup/s | PathPlan lookup/s | Speedup |
| --- | ---: | ---: | ---: |
| 1 | 7,490,868 | 25,231,572 | 3.368x |
| 2 | 7,634,311 | 25,317,938 | 3.316x |
| 3 | 7,562,267 | 24,757,505 | 3.274x |

The median process rates were 7,562,267 and 25,231,572 lookups/second,
respectively (about 3.34x). Every sample produced the same checksum. The
benchmark isolates path parsing/traversal and does not include the separate
regular-expression reuse change. It is a focused interpreter-hot-path
measurement, not a claim of a 3.3x whole-App or frame-rate improvement.

`tool/app_execution_plan_benchmark.dart` additionally measures eight mixed
templates after compiling an eight-widget dynamic App. Three Apple M4 Pro /
Dart 3.11.5 AOT processes measured:

| Process | Legacy templates/s | TemplatePlan templates/s | Speedup |
| --- | ---: | ---: | ---: |
| 1 | 1,230,295 | 6,747,815 | 5.485x |
| 2 | 1,230,660 | 6,729,710 | 5.468x |
| 3 | 1,231,799 | 6,863,619 | 5.572x |

All samples produced checksum `871685952`. Load-time compilation of this small
plan took 0.169–0.326 ms. This isolates template resolution; it does not yet
measure whole-screen rebuilds, Flutter layout/paint, or a complete App.

## Next plan candidates

The remaining full-plan work is to compile JSONLogic operators rather than
materializing their rule Maps, add per-widget property compilers, build a
path-aware mutation/dependency graph, and remove root-level rebuilds only after
every node on a screen has either a precise plan or an explicit wildcard legacy
host. Loop/event/params scopes, ParentData widgets, keys, stateful media/game
widgets, refs, dependencies, and mutable raw config require dedicated
compatibility contracts.

Each extension must retain the unoptimized behavior as its compatibility
reference, use bounded App-scoped storage, and demonstrate both semantic
equivalence and an AOT benefit on representative workloads before rollout.
