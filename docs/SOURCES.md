# Sources

Every non-obvious yt-dlp flag, format selector, template field and JSON key
used by YTGrab, grounded in the official yt-dlp README
(https://github.com/yt-dlp/yt-dlp#readme) AND the installed
`yt-dlp --help` (yt-dlp 2026.10.26). Anything not present in both was removed.

## Process / hardening flags

| Flag | Purpose | Source |
|------|---------|--------|
| `--ignore-config` | Don't load any configuration files | README "Filesystem Options"; `yt-dlp --help` |
| `--no-exec` | Remove any previously defined `--exec` (anti code-exec) | README "Post-Processing Options"; `--help` |
| `--no-plugin-dirs` | Clear plugin directories to search | README; `--help` |
| `--ffmpeg-location PATH` | Explicit ffmpeg dir (no PATH lookup) | README; `--help` |
| `--` before URL | Ends option parsing; URL can never be parsed as a flag | POSIX getopt convention; yt-dlp options.py |
| `ytsearchN:` | YouTube search extractor prefix | README "Supported sites" (`ytsearch:`); verified live |

## Download flags

| Flag | Purpose | Source |
|------|---------|--------|
| `-J` / `--dump-single-json` | Quiet JSON dump of the single result | README; `--help` |
| `--no-playlist` / playlist toggle off | Download only the video | README "Video Selection"; `--help` |
| `--newline` | Progress bar as new lines (parseable stream) | README; `--help` |
| `--progress-template "download:T"` | Custom progress output; `download:` type; fields under `progress.` | README "Verbosity"; `--help` |
| `progress._percent_str`, `_speed_str`, `_eta_str`, `_total_bytes_str` | Progress fields used by the default `[download] %(_default_template)s` line | README documents `progress.*` keyspace + `--progress-template`; field names verified live against installed 2026.10.26 (`downloader/common.py`) — values arrive right-aligned, unknowns render `N/A`/`NA`/`Unknown B/s` |
| `--retries 10`, `--fragment-retries 10` | Retries for whole downloads / fragments | README; `--help` |
| `-N`, `--concurrent-fragments 4` | Parallel fragment downloads | README; `--help` |
| `--windows-filenames` | Windows-compatible sanitized filenames | README; `--help` |
| `-P`, `--paths PATH` | Download directory | README; `--help` |
| `-o "%(title).150B [%(id)s].%(ext)s"` | Output template; `.150B` = truncate field to 150 **B**ytes | README "Output template" (B conversion, default template `%(title)s [%(id)s].%(ext)s`); `--help` |
| `--print after_move:filepath` | Print final path after post-processing | README (`--print` WHEN=after_move note); `--help` |
| `-f bv*+ba/b`, `-f bv*[height<=H]+ba/b[height<=H]` | Format selection: best video + best audio, height-capped | README "Format Selection"; `--help` |
| `--merge-output-format mp4|mkv|webm` | Merge container (supported: avi, flv, mkv, mov, mp4, webm) | README; `--help` |
| `-S ext:webm:webm` | Format sort: prefer webm ext for video & audio | README "Sorting Formats" (`ext` field, two preferred values for codec/ext); `--help` |
| `-x`, `--audio-format m4a|mp3` | Extract audio | README; `--help` |
| `--continue` / `--no-continue` | Resume / don't resume partial files | README; `--help` |
| `--force-overwrites` | Overwrite files; includes `--no-continue` | README; `--help` |
| `--cookies-from-browser chrome|safari|firefox` | Browser cookie source | README; `--help` |
| `--embed-metadata` | Embed metadata in the file | README; `--help` |
| `--write-subs --embed-subs --sub-langs LANGS` | Subtitles; `--embed-subs` works for mp4/webm/mkv; LANGS = comma list (regex allowed), leading `-` excludes (e.g. `all,-live_chat`) | README "Subtitle Options" + "Differences in behavior"; `--help` |
| `--flat-playlist` | Don't extract individual entries (fast listing) | README; `--help` |
| `-I`, `--playlist-items START:END` | Playlist item window for pagination | README "Video Selection"; `--help` |

Note: `--playlist-start`/`--playlist-end` exist in the option parser but are
`SUPPRESS_HELP` in 2026.10.26 (hidden); per the grounding rule they are not
used — `--playlist-items` covers the same windows.

## JSON keys consumed

`-J` output: `title`, `id`, `formats[].height`, `duration`, `uploader`,
`channel`. Flat-playlist output: `_type`, `title`, `entries[].id`,
`entries[].title`, `entries[].duration`, `entries[].uploader`,
`entries[].channel`, `entries[].view_count` (all optional in flat mode;
verified against real output for `ytsearch30:` and
`https://www.youtube.com/@SamayRainaOfficial/videos`).

## Apple APIs

| API | Source |
|-----|--------|
| `posix_spawn` + `POSIX_SPAWN_SETPGROUP` + `POSIX_SPAWN_CLOEXEC_DEFAULT` | `man posix_spawn` / Apple docs — child in its own process group so `kill(-pid, SIGSTOP/SIGCONT/SIGKILL)` signals the whole tree |
| `FileHandle.readabilityHandler` incremental pipe reads | Apple Foundation docs |
| `NSOpenPanel` (canChooseDirectories) | Apple AppKit docs |
| `NSWorkspace.activateFileViewerSelecting` | Apple AppKit docs |
| `URLSessionConfiguration.ephemeral` (no cookies/disk cache), `NSCache` | Apple Foundation docs |
| `NSApplicationDelegateAdaptor` + `applicationWillTerminate` | Apple SwiftUI/AppKit docs |
