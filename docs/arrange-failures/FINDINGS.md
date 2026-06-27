# Arrange Failure — FINDINGS (consolidated)

Audit of every edge case where `scrollwm arrange` leaves a window the user
expects to be tiled **floating / never caught**. Driven by a live repro on this
machine (see `00_BRIEF.md`). Per-gate detail in `gate_*.md`; tests in
`Sources/WindowLab/{IdentityMatcherFusionTests,TileabilityTests,ResyncFreezeTests}.swift`.

## Executive summary — the root-cause chain

The user ran `arrange` while ALREADY managing, so it dispatched to
`LifecycleMonitor.resync()`, and we caught it live in the exact failure state:
**`managing:true`, 1 tiled column, 42 Ghostty windows floating, every one
`canTile:true`** (standard, current-Space, eligible — but never adopted).

The failure is a **two-link chain**, both links independently proven by tests:

```
GATE-C  frame-only AX<->CG fusion misses a moving/churning window
  (CG titles need Screen Recording, never granted -> title bonus is DEAD;
   any >8px AX-vs-CG frame drift scores <=48 < 50 -> window read as "off-Space")
        |
        v
GATE-F  resync sees the strip's OWN columns as "not on current Space"
  -> ResyncPlanner returns .frozenDifferentSpace -> applyResync bails
  -> ZERO adopts this cycle -> every new tileable window stays floating
```

So "arrange didn't catch everything" = a robustness failure of the
**current-Space identity signal** (GATE-C/B) amplified into a **whole-cycle
freeze** (GATE-F). It is intermittent because once window motion settles the
frames re-agree and windows re-fuse (matches the live 42->0 flap). The user's
heavy spawn/close churn (jcode forest swarm) is exactly the condition that keeps
the snapshots disagreeing.

## Severity ranking (fix order)

1. **P0 — GATE-C (MATCH-C1/C2/C3): frame-only fusion drops real current-Space
   windows AND hides them from the floating menu.** The title bonus is dead in
   production, so fusion has no motion-invariant fallback. *Fix:* give fusion a
   motion-invariant signal (1:1 PID-count disambiguation; per-PID min-cost
   assignment) so a moved-but-present window matches without a same-instant frame.
2. **P0 — GATE-F (RESYNC-F1): `frozenDifferentSpace` cascade.** A current-Space
   strip whose columns transiently fail fusion freezes the whole resync. *Fix:*
   require POSITIVE evidence of a Space switch (`activeSpaceDidChange`) before
   freezing; otherwise prefer `.apply` so new windows are still adopted.
3. **P1 — GATE-F (F2/F3), GATE-G (G1/G2/G3), GATE-A (A1/A2/A3), GATE-B
   (B1/B2/B3), GATE-D (D1/D2), GATE-E (E1/E2).** Churn coalescing, degradation
   skip, accessory-app/timeout enumeration gaps, CG layer/size/occlusion filters,
   multi-display scope staleness, and non-standard-subrole apps never tiling.
4. **P2 — the remaining rows:** transient/self-healing or config-gated.

## Master table (all gates)

| ID | Gate | Trigger | Symptom | Sev | Repro |
|----|------|---------|---------|-----|-------|
| MATCH-C1 | C identity | AX & CG snapshots disagree >8px during churn | read off-Space -> never tiled/listed; reappears when motion stops | P0 | IdentityMatcherFusionTests |
| MATCH-C2 | C identity | CG titles need Screen Recording (never granted) | fusion is frame-only -> C1 has no fallback | P0 | IdentityMatcherFusionTests |
| MATCH-C3 | C identity | any C1/C2 miss | window absent from BOTH strip and floating menu | P0 | IdentityMatcherFusionTests |
| RESYNC-F1 | F resync | strip's own columns fail current-Space fusion while on this Space | resync freezes -> dozens of tileable windows never adopted | P0 | ResyncFreezeTests F1 + e2e |
| MATCH-C4 | C identity | app with more current-Space AX windows than fusable CG rows | surplus windows stranded `cg==nil` | P1 | IdentityMatcherFusionTests |
| MATCH-C5 | C identity | parked window's CG sliver clamped <64px | no CG candidate -> read off-Space | P1 | IdentityMatcherFusionTests |
| RESYNC-F2 | F resync | >half of a >=4 strip transiently missing | whole cycle skipped (`skipDegraded`) | P1 | ResyncFreezeTests F2 |
| RESYNC-F3 | F resync | rapid spawn/close faster than enumeration | overlapping resyncs coalesced away | P1 | reentrancy test (follow-up) |
| FAST-G1 | G fastadopt | WindowServer publish lags retry budget under burst | floats until a healthy resync | P1 | extend SpawnLatencyTest |
| FAST-G2 | G fastadopt | many created events during one enumeration | some new windows skipped | P1 | reentrancy churn test |
| FAST-G3 | G fastadopt | brand-new PID (each `open -na` Ghostty) | first window misses fast path | P1 | NewWindowAdoptTest fresh PID |
| ENUM-A1 | A enum | accessory/agent app opens a standard window | never tiled, never listed floating | P1 | live: 39 accessory + 32 prohibited apps |
| ENUM-A2 | A enum | cold/busy app or AX queue saturated by dozens of PIDs | app's windows skipped -> float | P1 | code trace, load-correlated |
| ENUM-A3 | A enum | dozens of PIDs spawning/closing | serial enumeration starves -> windows pile up floating | P1 | matches live churn |
| CGF-B1 | B cgfilter | always-on-top / panel terminal (non-zero layer) | no CG candidate -> never tiled/listed | P1 | live: 10 onscreen windows on layers 24/25 |
| CGF-B2 | B cgfilter | off-screen/parked window clamped to sliver | filtered candidate -> read off-Space | P1 | live: windows at x=-854 / x=1880 |
| CGF-B3 | B cgfilter | occlusion / animation / publish race | transient off-Space drop -> flapping floating | P1 | matches live 42->0 flap |
| SCOPE-D1 | D scope | external display unplugged, stale frames | window judged "not mine" -> floats | P1 | AdoptionScope unit test |
| SCOPE-D2 | D scope | window straddles bezel >50% on other monitor | adopted by neither strip -> floats | P1 | belongsToStripDisplay unit test |
| TILE-E1 | E tileability | app main window is AXDialog/AXFloatingWindow | listed floating, never tilable | P1 | TileabilityTests |
| TILE-E2 | E tileability | GLFW/SDL/Java/Electron nil-subrole primary window | neither tiled nor listed -> unreachable | P1 | TileabilityTests |
| MATCH-C6/C7/C8 | C identity | weak/`~` title; wrong CG row consumed; coord drift | edge drops / flapping | P2 | IdentityMatcherFusionTests / trace |
| RESYNC-F4/F5 | F resync | add re-filtered; stale CFEqual token mapping | add dropped / mis-counted | P2 | code trace |
| FAST-G4/G5/G6 | G fastadopt | mid-burst bail; stale destroyed slot; filter drift | new windows deferred/blocked | P2 | code trace |
| ENUM-A4/A5 | A enum | partial geometry read; non-deterministic order | window omitted / match flapping | P2 | code trace |
| CGF-B4/B5 | B cgfilter | mid-fade window; nil CG title | brief float; frame-only fusion | P2 | trace / see C2 |
| SCOPE-D3/D4 | D scope | off-screen frame; partition to dormant strip | mis-placed / claimed-but-dropped | P2 | partition unit test |
| TILE-E3/E4/E5 | E tileability | transient subrole; reveal->adopt; all-non-tileable | brief float; dialog floats; "arrange did nothing" | P2 | TileabilityTests |

## Verification status

```
.build/debug/WindowLab unittest
  [tileability] GATE-E: 29 passed, 0 failed
  IdentityMatcher fusion (GATE-C): 13 passed, 0 failed
  [resyncfreeze] GATE-F: 8 passed, 0 failed
```
All three audit suites are wired into `unittest` and PASS as assertions of the
CURRENT (buggy) behavior; each `// BUG:` check marks exactly what a fix must
flip. Gates A/B/D are documented from code-read + live measurement (their pure
predicates — `AdoptionScope`, `looksManageable` — are unit-testable next).

## Recommended single highest-leverage fix
Harden the **current-Space identity signal** (GATE-C) and **gate the freeze**
(GATE-F2) together: a moved/churning managed column should stay recognized as
on-Space (so resync never false-freezes), and the freeze should require positive
Space-switch evidence. That one change neutralizes the P0 chain that produced the
user's "1 column / 42 floating" report.
