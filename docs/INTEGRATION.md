# ScrollWM control-plane integration contract

This is the canonical wire contract for driving ScrollWM from another program.
It is consumed by **jcode** (<https://github.com/1jehuang/jcode>), whose Rust
client lives in `crates/jcode-scrollwm`, but it is generic: anything that can
write a line to a Unix socket can use it.

ScrollWM is a macOS scrolling window manager. It is **dormant by default** and
only manages windows after an explicit `arrange`. The control surface below
never violates that contract: clients drive arrange/focus/workspace, ScrollWM
remains the authority on window placement and the "never break the desktop"
guarantees.

## Transport

- **Socket:** `~/Library/Application Support/ScrollWM/control.sock`
  (Unix domain, `SOCK_STREAM`, mode `0600`, owner-only). Override with the
  `SCROLLWM_CONTROL_SOCK` environment variable (used by sandbox mode and tests).
- **Framing:** connect, write one request line `"<verb> [args]\n"`, half-close
  the write side (`shutdown(SHUT_WR)`), read the reply to EOF, trim. One request,
  one reply, per connection.
- **Replies:** a single human-readable line, except `status` and `version`,
  which return a JSON object. A reply beginning with `error:` denotes a
  command-level failure.
- **Not running:** connecting to a missing socket (`ENOENT`) or a stale socket
  (`ECONNREFUSED`) means ScrollWM is not running. Treat this as "absent", not an
  error; the `scrollwm` CLI maps it to exit code 3.

The reference server is `Sources/WindowLab/ControlServer.swift`; the reference
Swift client is `ControlClient.send` in the same file; the dispatch is
`ControlCommands.handleControlCommand`.

## Handshake (feature detection)

Clients should detect compatibility via the handshake rather than pinning a
marketing version.

`version` (alias `hello`) returns:

```json
{
  "name": "ScrollWM",
  "version": "0.2.0",
  "protocol": 1,
  "capabilities": ["ping","status","version","arrange","release","toggle",
                   "focus","move","workspace","width","close","display",
                   "focus-mode","reload"],
  "verbs": ["...same as capabilities..."]
}
```

- `protocol` (integer) is the **coarse** compatibility gate. It is bumped ONLY
  on a breaking change to an existing verb's arguments or to the status/version
  JSON shape. Adding a new verb or a new capability flag is **non-breaking** and
  does not bump it.
- `capabilities` (and its `verbs` alias) is the **fine-grained** feature list.
  Gate optional behavior on `capabilities.contains("X")`.
- `version` is display-only marketing version (`CFBundleShortVersionString`).

The same `version` and `protocol` fields are also mirrored into `status`, so a
single `status` call yields both the live strip state and the handshake.

Compatibility policy:
- Older ScrollWM without the `version` verb replies `error: unknown command`.
  Clients should treat that as `protocol = 0` and fall back to the v0 verb set.
- Newer ScrollWM just adds capabilities; older clients ignore the extras.

## Verbs

| Verb (aliases) | Args | Reply | Needs managing? |
|---|---|---|---|
| `ping` | - | `pong` | no |
| `version` (`hello`) | - | JSON handshake | no |
| `status` | - | JSON strip snapshot | no |
| `arrange` | - | `ok: arranged N windows` / `error: nothing to arrange` | no (starts managing) |
| `release` | - | `ok: released, all windows restored` | no |
| `toggle` | - | `ok: arranged N` / `ok: released` | no |
| `focus` | `next\|prev\|left\|right\|N` | `ok: focused column K (title)` | yes |
| `move` | `left\|right\|up\|down` | `ok: moved ...` | yes |
| `workspace` (`ws`) | `up\|down\|N` (or none) | `ok: on workspace K of M` | yes |
| `width` | `25\|50\|75\|100\|0.0-1.0` | `ok: set focused width to P%` | yes |
| `close` | - | `ok: closed <title>` | yes |
| `display` | `next\|main\|primary\|largest\|N` (or none) | `ok: displays: ...` | no |
| `focus-mode` (`focusmode`) | `fit\|centered` (or none) | `ok: focus-mode set to X` | no |
| `reload` (`reload-config`) | - | `ok: config reloaded` | no |
| `update` (`update-check`) | `[--install]` | update status line | no |
| `quit` | - | `ok: quitting (windows restored)` | no |

> ⚠️ `arrange` adopts **every** manageable window on the current Space, not just
> the caller's windows. A client that only wants to tile windows it created
> should rely on ScrollWM's automatic adoption of new windows while it is
> already managing, and avoid calling `arrange` implicitly.

### `status` JSON shape

```jsonc
{
  "managing": true,
  "focusMode": "fit",
  "windowCount": 3,
  "version": "0.2.0",          // handshake mirror
  "protocol": 1,               // handshake mirror
  // present only while managing:
  "focusedColumn": 1,          // 1-based
  "workspace": 1,              // 1-based
  "workspaceCount": 1,
  "floatingCount": 0,
  "floating": [{ "app": "...", "title": "...", "canTile": true }],
  "columns": [
    { "index": 1, "app": "Ghostty", "title": "🛰 jcode/aqua main",
      "width": 800, "focused": true, "healthy": true }
  ]
}
```

Columns are identified by `app` + `title` (there is no per-column PID). Clients
that need to focus a specific window should set a unique, stable window title and
match on it: read `status`, find the column whose `title` contains the marker,
then `focus N`. jcode does exactly this with its per-session window title.

## How jcode uses this

- **Detection:** `ping` for liveness; `version` for capabilities.
- **Tiling headed swarm agents:** after spawning a headed agent terminal, jcode
  (when `agents.scrollwm.enabled`) reads `status` and `focus`es the agent's
  column by matching the agent's unique session name in the window title. It does
  not call `arrange` unless the user opts into `arrange_on_spawn`.
- The jcode side is best-effort: every call is fire-and-log, so ScrollWM being
  absent or older never affects jcode.

## Conformance

`Sources/WindowLab/ControlContractTests.swift` (run via `WindowLab unittest`)
asserts the advertised `capabilities` stay a subset of the real verb set and
that the `version`/`status` JSON carry the handshake fields, so this document and
the code cannot silently drift.
