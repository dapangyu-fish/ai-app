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

## Next plan candidates

The same design can be extended independently to templates, action arguments,
JSON-Logic expressions, and repeated widget/game entity definitions. Each
extension must retain the unoptimized behavior as its compatibility reference,
use bounded App-scoped storage, and demonstrate both semantic equivalence and
an AOT benefit on representative workloads before rollout.
