# Signing & notarization

ScrollWM can be built and distributed at three signing tiers. The build scripts
auto-detect the best one available, so you only set this up once.

| Tier | Apple account? | Local Accessibility grant | Downloaded copy |
|------|----------------|---------------------------|-----------------|
| ad-hoc (`-`) | no | re-granted on each rebuild | Gatekeeper warns; right-click → Open |
| self-signed (`scripts/setup-signing.sh`) | no | **persists** across rebuilds | Gatekeeper warns; right-click → Open |
| **Developer ID + notarized** | **yes ($99/yr)** | **persists** | **opens with no warning** |

Identity preference is centralized in `scripts/signing-lib.sh`:
**Developer ID > "ScrollWM Self-Signed" > ad-hoc**. Override with
`SCROLLWM_SIGN_ID="..."`.

The bundle's main executable is the real Mach-O (`Contents/MacOS/ScrollWM`,
`CFBundleExecutable=ScrollWM`); there is no shell-script wrapper, because a
script main-executable cannot carry a hardened-runtime signature and breaks
notarization. The binary decides what to do from how it is launched: a bare
launch as an `.app` runs the production menu-bar agent; any subcommand
(`status`, `arrange`, `probe`, `unittest`, ...) still works for the `scrollwm`
CLI and the lab harness.

---

## Local development (no Apple account)

Nothing special needed: `swift build` then run `.build/debug/WindowLab ...`.
Local builds are never quarantined.

To stop macOS from dropping the Accessibility grant on every rebuild, create a
stable identity once:

```bash
./scripts/setup-signing.sh     # makes a local "ScrollWM Self-Signed" cert
./scripts/update.sh            # installs signed with it; re-grant Accessibility once
```

If you already have a Developer ID cert installed, you can skip the self-signed
cert entirely: the scripts prefer the Developer ID identity automatically, so
local installs use the same identity as releases.

---

## Notarized distribution (Apple Developer account)

### Fastest path: the guided setup

```bash
./scripts/setup-developer-id.sh     # or: make notary-setup
```

This walks you through the two steps that need your Apple ID (cert + notary
credentials), validates each, and can optionally push the GitHub Actions secrets
for you. It is idempotent. The manual equivalents are below if you prefer.

### One-time setup (manual)

1. **Install a Developer ID Application certificate.**
   Xcode → Settings → Accounts → (your team) → Manage Certificates →
   **+ → Developer ID Application**. Verify:

   ```bash
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```

2. **Store notary credentials** in your keychain under a profile name. Use an
   app-specific password (create one at <https://account.apple.com> →
   App-Specific Passwords) and your 10-character Team ID:

   ```bash
   xcrun notarytool store-credentials scrollwm-notary \
     --apple-id "you@example.com" \
     --team-id  "ABCDE12345" \
     --password "abcd-efgh-ijkl-mnop"
   ```

   (An App Store Connect API key via `--key/--key-id/--issuer` works too.)
   Override the profile name anywhere with `SCROLLWM_NOTARY_PROFILE=...`.

### Cut a release

One command does build → notarize → cask (and optionally the GitHub Release):

```bash
make release                 # = scripts/release.sh <VERSION>
make release-publish         # ...and upload the GitHub Release via gh
# or explicitly:
./scripts/release.sh 0.1.2 [--publish]
```

Under the hood that runs the three steps (also usable individually):

```bash
./scripts/package-release.sh 0.1.2   # universal build, Developer ID + hardened runtime
./scripts/notarize.sh 0.1.2          # submit to Apple, staple, repackage zip/dmg
./scripts/update-cask.sh 0.1.2       # sync the Homebrew cask sha256
```

`notarize.sh` is safe to run repeatedly and:

- refuses to start unless a Developer ID cert and the notary profile exist
  (clear, actionable errors otherwise);
- builds + signs first if `dist/` is empty;
- submits `dist/ScrollWM-<ver>.zip` with `notarytool submit --wait`;
- staples the ticket onto the `.app` (and the `.dmg`);
- **repackages** the zip/dmg so the published artifacts contain the stapled
  ticket (a stapled app opens offline with no warning);
- runs a final `spctl --assess` / `stapler validate` sanity check.

`update-cask.sh` detects the stapled bundle and **drops the quarantine-stripping
`postflight`** from the cask: a notarized app needs no `xattr` workaround.

### CI

`.github/workflows/release.yml` runs the same flow on a `v*` tag (or manual
dispatch) **when these repo secrets are set**; if they are absent it falls back
to an ad-hoc build, so the workflow never breaks:

| Secret | Meaning |
|--------|---------|
| `DEVELOPER_ID_CERT_P12` | base64 of your exported `.p12` (cert + private key) |
| `DEVELOPER_ID_CERT_PASSWORD` | password for that `.p12` |
| `NOTARY_APPLE_ID` | Apple ID email used for notarization |
| `NOTARY_TEAM_ID` | 10-character Developer Team ID |
| `NOTARY_PASSWORD` | app-specific password for the Apple ID |

Export the `.p12` from Keychain Access (right-click the Developer ID identity →
Export), then:

```bash
base64 -i DeveloperID.p12 | pbcopy    # paste into the DEVELOPER_ID_CERT_P12 secret
```

---

## Why not the Mac App Store?

ScrollWM is a window manager: it controls other apps' windows via the
system-wide Accessibility API. The App Sandbox required by the Mac App Store
forbids that, and the project's contract is "one permission (Accessibility), no
private APIs." Notarized Developer ID distribution is the correct path; the App
Store is not viable for this kind of tool.

---

## Troubleshooting

- **`codesign` fails with `errSecInternalComponent`** after creating an identity:

  ```bash
  security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "" ~/Library/Keychains/login.keychain-db
  ```

- **Notary rejects the submission.** Inspect the log:

  ```bash
  xcrun notarytool history --keychain-profile scrollwm-notary
  xcrun notarytool log <submission-id> --keychain-profile scrollwm-notary
  ```

  The most common cause is a missing hardened runtime; `make-bundle.sh` warns if
  the runtime flag did not stick after signing.

- **A signature/identity change requires re-granting Accessibility once.** Toggle
  ScrollWM off/on in System Settings → Privacy & Security → Accessibility.
