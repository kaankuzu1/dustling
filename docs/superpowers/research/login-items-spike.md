# Login items / startup items spike

Date: 2026-11-08. Machine: macOS 26.x (Darwin 27.2.0), unsandboxed shell as the logged-in user, no sudo.
Only read-only commands were run; nothing was toggled. Item labels and counts only are recorded here.

## Findings per scope

| Scope | Listable without root? | How enablement is read | Toggle without admin? |
|---|---|---|---|
| User launch agents (`~/Library/LaunchAgents`) | Yes: plain directory listing of `*.plist` | `launchctl print-disabled gui/<uid>` (plus `Disabled = true` in the plist) | Yes: `launchctl disable/enable gui/<uid>/<label>` plus `bootout`/`bootstrap`, reversible |
| System launch agents (`/Library/LaunchAgents`) | Yes: world-readable directory | `launchctl print-disabled gui/<uid>` for the per-user override database (same domain as user agents) | No: enabling/disabling in `system` needs root. Reported as needs-admin |
| Launch daemons (`/Library/LaunchDaemons`) | Yes: world-readable directory | `launchctl print-disabled system` (worked without root here, ~36 lines) | No: needs root. Reported as needs-admin |
| Login items / BTM (`SMAppService`, Background Items in System Settings) | See below | See below | No supported API; only the user can toggle it in System Settings |

### Observed commands

- `launchctl print-disabled gui/$(id -u)` ran without root, exit 0, ~40 lines. Format:
  `"<label>" => disabled` or `=> enabled` inside a `disabled services = { ... }` block. Older macOS printed `true`/`false`; the parser accepts both.
- `launchctl print-disabled system` also ran without root, same format.
- `ls` of `~/Library/LaunchAgents`, `/Library/LaunchAgents`, `/Library/LaunchDaemons` all succeeded (36 entries combined).
- `sfltool dumpbtm` exited 0 here and printed ~1,000 lines for 3 UID records, with entries typed `app`, `agent`, `daemon`, `legacy agent`, `legacy daemon`, `developer`, `quicklook` and others, each with a `Disposition: [enabled|disabled, allowed|disallowed, notified|not notified]` line. This session's shell is unsandboxed and may hold elevated privileges (Full Disk Access) that a sandboxed or notarized app will not; on a default account `sfltool dumpbtm` is documented and commonly reported to require root, so the success here cannot be relied on. The output is a human-readable text dump: unversioned, undocumented and free to change between macOS releases.
- BTM database: `/private/var/db/com.apple.backgroundtaskmanagement/` (reading it directly gives "Operation not permitted", SIP/TCC protected). A per-user file `~/Library/Application Support/com.apple.backgroundtaskmanagementagent/backgrounditems.btm` exists but is an opaque archive.
- `SMAppService.statusForLegacyPlist(at:)` (Swift name of `statusForLegacyURL:`): on one existing user agent plist it returned `requiresApproval` (raw 2), on a nonexistent path and on an `.app` it returned `notRegistered` (raw 0, not `notFound`). It reports the BTM approval state of a legacy plist but cannot enumerate items, cannot change state, and returns a misleading "not registered" for unknown paths, so it is not a reliable enablement source.
- Items registered via `SMAppService.mainApp` (true "Login Items" the user sees under "Open at Login") have no public enumeration API for other apps' registrations.

## Decision: `loginItem` support

**No `loginItem` rows in this plan (Plan 1).** The only enumeration route is parsing `sfltool dumpbtm`, which (a) probably needs root for a normal app, (b) has an unstable, undocumented text format, and (c) cannot be toggled by us anyway. The `.loginItem` scope stays in `StartupScope` and `setEnabled` on it returns a `.failed` outcome that says it can only be managed in System Settings (deep link: `x-apple.systempreferences:com.apple.LoginItems-Settings.extension`), instead of pretending. Gap marked for Plan 2: a privileged helper (or user-approved Full Disk Access) could read BTM; even then the UI should link to System Settings for toggling.

## Implementation consequences

- Agents and daemons are discovered by listing plists, and enablement comes from `print-disabled`. If `print-disabled` fails, a `ScanIssue.commandFailed` is surfaced rather than silently assuming "enabled".
- Toggle for user agents: disable = `launchctl disable gui/<uid>/<label>` then `bootout gui/<uid>/<label>`; enable = `enable` then `bootstrap gui/<uid> <plist>`.
- Agents installed by apps through `SMAppService` live inside the app bundle, not in these directories, so they are not listed (same gap as login items).
