import Foundation

// CONTROLLER / CONFIG / CONTROL-SOCKET fuzzer (owned by the `fuzzctrl` agent).
//
// Goal: fuzz the full app surface that touches untrusted input:
//   - random CHORD sequences through the real `ScrollWMController`
//     (`debugDeliverChord`) after a headless arrange, asserting it never
//     crashes / desyncs and management state stays coherent;
//   - JSONC `ScrollWMConfig.parse` on random/garbled input (never traps,
//     always falls back sanely);
//   - `ControlCommands` verb+arg parsing (the `scrollwm <verb>` surface);
//   - `Chord(string:)` and width/arg parsing on arbitrary strings.
//
// Reuse `SplitMix64` from Fuzz.swift. Production edits allowed ONLY in
// Config.swift / ControlCommands.swift / ControlCLI.swift; report anything else
// to the coordinator. Keep all logic self-contained here; encode regressions as
// fixed seeds. Entry point wired in main.swift.
func runFuzzController(args: [String]) -> Never {
    print("fuzzctrl: not yet implemented")
    exit(0)
}
