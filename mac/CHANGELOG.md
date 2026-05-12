# Changelog

## Initial build — 2026-05-11

No design departures from `CURSOR_PROMPT.md`. Documenting only the tactical
implementation calls that the spec left to judgement:

- **`monitor.sh` uses `set -uo pipefail` (no `-e`) with an `EXIT` trap that
  forces `exit 0`.** The spec mandates monitor.sh always exit 0 so launchd
  never throttles the job. Pairing relaxed strict-mode with a forced-zero
  EXIT trap means a stray failed command still gets logged via the trap
  branch but does not propagate to launchd as a failure.
- **`notify.sh` runs `osascript` directly when invoked by the console user
  (e.g. `tunnel-check --test-notify`), and routes through `launchctl asuser
  <uid> osascript ...` when invoked by the root daemon.** Same code path,
  the script just detects `id -u == 0` and switches strategies. Lets the
  operator validate notifications without sudo.
- **`com.example.tunnel-monitor.plist` puts `/opt/homebrew/bin` ahead of
  `/usr/local/bin` in PATH** so root-launched `monitor.sh` finds `jq` on
  Apple Silicon. Also sets `ProcessType=Background`, `LowPriorityIO=true`,
  and `Nice=5` — none of these change behaviour, but they signal to the
  scheduler that this is a tolerant background workload.
- **`ssh-router-state.sh` validates the remote state line against
  `^[0-9]+:(UP|DOWN)$`** before printing it. If the router monitor ever writes
  garbage we treat the read as a failure (-> router_UNREACHABLE diagnosis)
  instead of feeding the diagnosis tree malformed input.
- **`ssh-router-state.sh` pins `UserKnownHostsFile` to
  `/opt/tunnel-monitor/.ssh/known_hosts`** so root's global `~/.ssh/known_hosts`
  isn't relied upon and `accept-new` host pinning is scoped to this daemon.
- **router state is queried on every check, not only when the tunnel is
  down.** Slightly more SSH traffic (~one connection every 5 minutes), but
  `state.json.router_dedup` is always populated so the SwiftBar plugin can
  surface the dedup section continuously.
- **`build_email_body` extracts the Mac's local interface via `route get`
  and its IP via `ipconfig getifaddr`.** Matches the router email body's
  "Tunnel Endpoints" section without hard-coding `en0`.
