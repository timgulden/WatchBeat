# Architecture Remediation Plan

**Goal:** bring the codebase to a level that holds up to review by a first-rate
software architect — without changing functionality. Drafted 2026-05-02 from
an honest assessment of the current state.

## Context

The DSP-app boundary (`WatchBeatCore` package with no iOS dependencies) is
genuinely well-designed and should be preserved. Beyond that boundary, the
code has grown organically, and several patterns a senior reviewer would
flag have accumulated. None are bugs in the current behavior; all are
maintainability and clarity concerns.

This plan is sized to fit single-session chunks, ordered by value-per-risk.
Each phase is independently shippable. After Phase 1 the code is
*defensible*; after Phase 2 it's *legible*; after Phase 3 it's *elegant*;
after Phase 4 it's *first-rate*.

## Current pain points (the audit)

### Size and cohesion
- **`MeasurementPipeline.swift`** is 1,808 lines, 22 functions. Two parallel
  full pipelines (`measure`, `measureReference`) live side-by-side with zero
  shared abstraction. Each computes envelopes, tries all rates, and regresses
  separately.
- **The Reference picker** is one ~500-line function with nested `Candidate`
  struct, nested `fitQuadratic` closure, nested `cleanClass` closure. Hard
  to test in isolation, hard to navigate.
- **`ContentView.swift`** is 1,015 lines holding 11 distinct views. Standard
  SwiftUI practice is one screen per file.
- **`MeasurementCoordinator`** does state management + audio orchestration +
  recording loop + best-window scoring + routing ladder — four separable
  concerns under one roof.

### Type discipline
- **`MeasurementDisplayData` has a hand-rolled `==`** that compares only 4
  of its ~12 fields, because it carries a tuple-typed property
  `tickResiduals: [(index: Int, residualMs: Double, isEven: Bool)]` that
  blocks auto-`Equatable`. The same data already exists as `TickTiming`
  in `MeasurementResult`. **One concept, two representations, broken
  equality.**
- **`error(String)` state with prefix-matching routing.** `ErrorScreen`
  distinguishes mic-unavailable from low-confidence by
  `message.hasPrefix("Microphone access denied")`. The Snap Confusion bug
  fixed earlier today (2026-05-02) was an instance of this trap; mic-
  unavailable and low-confidence still rely on it. The same bug class will
  recur for the next error type added.

### Boundaries and coupling
- **Diagnostics bolted on as tuples.** Both `measureWithDiagnostics` and
  `measureReferenceWithDiagnostics` return `(MeasurementResult,
  PipelineDiagnostics)`. Diagnostics is a separate concern shoehorned into
  the result API.
- **No dependency injection.** `MeasurementCoordinator` instantiates
  `AudioCaptureService`, `FrequencyMonitor`, `OrientationMonitor`,
  `MeasurementPipeline` directly. Untestable without a real microphone.
- **Magic thresholds scattered.** Some live in `MeasurementConstants`
  (`autoStopQuality`, `minimumDisplayQuality`); others are inline (`>= 0.5`,
  `>= 0.8`, `> 7%`, `> 10ms`). Inconsistent.

### Naming and clarity
- Internal naming inconsistencies (e.g. `confirmedFraction` and `cf`
  for the same value in the same scope).
- `PipelineDiagnostics` has grown organically; pulls fields from everywhere.
- No curated public API surface — `public` modifiers added per-need.

---

## Phased plan

### Phase 1 — Type safety, low risk (~2 sessions)

Surgical changes that unlock other work.

1. **Replace `error(String)` with typed error cases.**
   Add `case micUnavailable`, `case micPermissionDenied`,
   `case lowAnalyticalConfidence`, `case weakSignal(diagnostics: String)`.
   Delete prefix-matching from `ErrorScreen`. Each error case has a
   dedicated screen variant chosen by the state, not a string prefix.
2. **Eliminate tuple `tickResiduals`.** Pass `[TickTiming]` directly to
   `TimegraphView`. Remove the duplicate tuple representation.
   `MeasurementDisplayData` becomes auto-`Equatable`.
3. **Centralize ALL routing thresholds in `MeasurementConstants`** with
   named constants and short doc comments
   (`autoStopConfirmedFraction = 0.80`, `weakSignalMinTickCount = 3`,
   `snapMismatchMaxFraction = 0.07`, etc.). Routing logic should read
   like a specification.

### Phase 2 — File-level decomposition, medium risk (~2 sessions)

4. **Split `ContentView.swift` into per-screen files.** `IdleScreen.swift`,
   `MonitoringScreen.swift`, `RecordingScreen.swift`, `ResultScreen.swift`,
   `NeedsServiceScreen.swift`, `RateConfusionScreen.swift`,
   `ErrorScreen.swift`, `SquareScreenLayout.swift`. `ContentView.swift`
   becomes a 30-line state switch.
5. **Extract `RecordingSession` from `MeasurementCoordinator`.** The
   100-line recording loop with best-window scoring becomes its own type
   that the coordinator drives. Coordinator drops to ~250 lines focused on
   state + lifecycle.
6. **Extract `Router` from `MeasurementCoordinator`.** The routing ladder
   becomes a pure function `Router.classify(result, diagnostics) -> State`.
   Testable without a coordinator.

### Phase 3 — DSP architecture, higher risk (~3–4 sessions)

7. **Define `Picker` protocol.** Two implementations: `ProductionPicker`,
   `ReferencePicker`. `MeasurementPipeline` becomes a thin facade that
   selects and calls a picker. Each picker file is ~600 lines but has one
   job.
8. **Extract shared building blocks.** `Envelope.swift` (envelope + FFT
   helpers), `LinearRegression.swift`, `QuadraticRegression.swift`,
   `MAD.swift` (robust statistics). Both pickers consume these.
9. **Replace nested closures inside Reference picker with named types.**
   `Candidate` becomes a top-level struct in its own file;
   `fitQuadratic`/`cleanClass` become methods on an `OutlierRejector` type.

### Phase 4 — Testability and concurrency, optional (~2 sessions)

10. **Dependency injection for `MeasurementCoordinator`.** Init takes
    `AudioCaptureProvider`, `FrequencyAnalyzer`, `Pipeline` protocols.
    Mock implementations let the coordinator be tested in isolation.
11. **Diagnostics as a structured side channel.** Pipeline takes an
    optional `DiagnosticsCollector` parameter rather than always returning
    a tuple. Production code passes nil; AnalyzeSamples passes a real
    collector.

---

## Discipline for execution

- **One phase, one branch-equivalent commit chain.** Don't mix Phase 1
  type-safety work with Phase 2 file moves — review them separately.
- **Functionality unchanged at every commit.** All 83 swift tests must
  pass; corpus output (AnalyzeSamples on `SoundSamples/`) should be
  byte-identical before and after each phase. If a phase's diff would
  change output, it's not a refactor — pause and discuss.
- **Each phase ends with the architecture notes in CLAUDE.md updated**
  to reflect the new structure, so the next session has accurate context.

## Status

- [x] Phase 1.1 — Typed error cases (commit `d04b307`)
- [x] Phase 1.2 — Eliminate tuple tickResiduals (commit `c4a76f6`)
- [x] Phase 1.3 — Centralize routing thresholds
- [x] Phase 2.4 — Split ContentView per screen (commit `907afe6`)
- [x] Phase 2.5 — Extract RecordingSession (commit `6ad2216`)
- [x] Phase 2.6 — Extract Router
- [x] Phase 3.7 — Picker protocol (BeatPicker + AmplitudeMeasuring); paired with 4.10
- [x] Phase 3.8 (partial) — Pure utility helpers extracted to PipelineUtilities.swift
  - movingAverage, sortedMedian, sortedMedianInt, nextPowerOfTwo are now top-level
    functions (no class membership). Used by both pickers, no state needed.
  - Bigger building-block extractions (envelope FFT, regression) deferred — both
    pickers compute these slightly differently; consolidating without behavior
    change requires careful equivalence proofs that aren't worth doing
    speculatively. Will revisit when a specific bug or duplication motivates it.
- [x] Phase 3.9 — Replace nested closures with named types (commits `fc530e6`, this commit)
  - Sub-step: Reference picker also moved to its own file (ReferencePipeline.swift) as
    an extension on MeasurementPipeline — same intent (decompose the giant function)
- [x] Phase 4.10 — Dependency injection for coordinator (BeatPicker + AmplitudeMeasuring)
- [ ] Phase 4.11 — Diagnostics as structured side channel (DEFERRED — see notes)
  - The "tuple is bolted on" smell isn't actually painful in practice. The iOS
    app discards the diagnostics it doesn't need; AnalyzeSamples uses them in
    full. Wrapping the (MeasurementResult, PipelineDiagnostics) tuple in a
    MeasurementOutcome struct would add a layer without revealing intent. The
    BeatPicker protocol's tuple return makes the contract explicit. Worth
    revisiting if a third caller appears with different needs.

Update this list as items complete. Phases need not be sequential after
Phase 1 — Phase 2 and Phase 3 work can be interleaved, but each item
should be reviewed in isolation.
