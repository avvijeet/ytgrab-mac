# Architecture

## Layers

```
UI/          SwiftUI views only — no business logic
  YTGrabApp.swift      @main, AppDelegate → terminateAll on quit
  ContentView.swift    Downloads tab: URL/fetch, quality picker, folder,
                       settings, job rows; DownloadForm shared state
  BrowseView.swift     Browse tab: search/channel input, results grid,
                       multi-select, thumbnails

Services/    Process and state management
  Tooling.swift        Binary resolution (fixed dirs only), child env,
                       ProcessSpawner protocol, posix_spawn impl
                       (SETPGROUP → whole-tree signalling), LineAssembler,
                       ExitCoordinator, LockedBox
  JSONRunner.swift     Shared `yt-dlp -J` runner: streams lines, caps
                       output at 64 MB, captures last stderr line,
                       exposes spawned process via onSpawned seam
  DownloadManager.swift @MainActor queue: enqueue/pump (max 2 running),
                       pause/stop/restart/resume/remove/reveal plumbing,
                       progress application (throttled 5/s/job),
                       UserDefaults persistence
  BrowseManager.swift  @MainActor browse runs: classify → spawn → parse;
                       new run cancels previous; 60 s timeout; runID
                       invalidates stale completions
  ThumbnailStore.swift i.ytimg.com-only loads from regex-validated ids;
                       ephemeral URLSession; NSCache (400 imgs / 64 MB)
  DownloadJob.swift    @Observable job model + JobState/JobPhase enums

Domain/      Pure value types — no AppKit/SwiftUI imports
  Models.swift         VideoQuality, VideoContainer, CookieBrowser,
                       DownloadSettings, DownloadSpec, VideoInfo,
                       BrowseTarget, BrowseEntry
  YTDLPCommand.swift   The ONLY argv builder (download/info/browse),
                       shared hardeningFlags
  URLValidator.swift   https+host whitelist, path-shape validation,
                       browse-input classification, search sanitizer
  ProgressParser.swift `a|b|c|d` progress lines, postprocess + filepath
                       detection (split on '|', no regex in hot path)
  SubtitleLangsValidator.swift  --sub-langs value validation

Tests/YTGrabTests/     Unit (validator/argv/parser/manager state machine
                       via FakeSpawner) + IntegrationTests (real yt-dlp,
                       gated on YTGRAB_E2E=1)
```

## Job state machine

| From | Action | To | Notes |
|------|--------|-----|-------|
| queued | pump (slot free) | running | max 2 concurrent |
| running | Pause | paused | SIGSTOP to process group |
| paused | Resume | running | SIGCONT to process group |
| running/paused | Stop | stopped | SIGCONT+SIGKILL group; .part kept → Resume re-runs `--continue` |
| running/paused | Remove | (deleted) | SIGCONT+SIGKILL group, entry dropped |
| stopped/failed/cancelled | Resume | running | `--continue` |
| stopped/failed/cancelled/done | Restart | running | `--no-continue --force-overwrites` |
| running | exit 0 | done | finalPath from `--print after_move:filepath` |
| running | exit≠0 / signal | failed | last stderr line surfaced |
| queued | Stop | stopped | no process to kill |
| any | Clear finished | (removed) | done/failed/stopped/cancelled |

## Threat model → controls

| Threat | Control |
|--------|---------|
| Command injection via URL/query | argv arrays only, no shell; `--` before user input; validator rejects options-looking, non-https, non-whitelisted-host, userinfo, control/whitespace, traversal, bad query keys |
| yt-dlp config/plugins/exec escalation | `--ignore-config --no-exec --no-plugin-dirs` on every invocation |
| Binary hijack via PATH | binaries resolved only in /opt/homebrew/bin, /usr/local/bin via isExecutableFile; minimal env PATH; `--ffmpeg-location` explicit |
| Credential/cookie leakage | cookies opt-in only; child env = PATH/HOME/LANG only; no inherit |
| Thumbnail SSRF/tracking | thumbnail URL built from `^[A-Za-z0-9_-]{11}$` id at fixed i.ytimg.com host; ephemeral session, no cookies, no disk cache; JSON thumbnail URLs never used |
| Zombie children on quit/pause | children in own process groups; SIGSTOP/SIGCONT pause whole tree incl. ffmpeg; SIGCONT+SIGKILL on stop/quit |
| Unbounded output memory | stdout streamed line-by-line; -J JSON capped at 64 MB; only last stderr line kept per job |
| Search-query injection | `ytsearchN:` prefix + `--` — query can never be parsed as an option; ≤200 chars, no control chars |
| Bad `--sub-langs` value | strict token validator; UI blocks Download while invalid |
| App sandbox bypass | NOT sandboxed — sandbox would forbid exec'ing /opt/homebrew binaries; mitigations above instead |

## Complexity notes

- Progress path: split on `|` O(len); job lookup O(1) via `jobByID`;
  UI publish throttled to ≤5/s per job.
- Browse dedupe: `Set<String>` of ids — O(1) per entry, ordered array kept.
- Thumbnails: NSCache bounded (400 / 64 MB); `.task` cancellation aborts
  loads for offscreen rows.
- Queue: jobs array is display order; contexts keyed by UUID O(1).
