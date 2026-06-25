import Foundation

// MULTI-DISPLAY / GEOMETRY / RESTORE fuzzer (owned by the `fuzzdisp` agent).
//
// Goal: fuzz the multi-monitor + restore bug surface:
//   - random display HOTPLUG sequences (add/remove/resize/rearrange/sleep-wake,
//     negative origins, stable IDs) through `StripDisplayResolver` and the
//     engine's `rebindStripDisplay`, asserting the strip never strands windows
//     off every display and the resolver's choice is always in range;
//   - parking-corner policy (`computeParkingPoint`) across arbitrary layouts;
//   - `AdoptionScope` / `DisplayGeometry` / `DisplaySelector` property checks;
//   - `RestoreStore` save/load round-trips + display-safe restore targets under
//     unplugged monitors.
//
// Reuse `SplitMix64` from Fuzz.swift. Production edits allowed ONLY in
// DisplayGeometry.swift / StripDisplayResolver.swift / DisplaySelector.swift /
// AdoptionScope.swift / RestoreStore.swift; report engine/main changes to the
// coordinator. Keep all logic self-contained here. Entry point wired in main.swift.
func runFuzzDisplay(args: [String]) -> Never {
    print("fuzzdisp: not yet implemented")
    exit(0)
}
