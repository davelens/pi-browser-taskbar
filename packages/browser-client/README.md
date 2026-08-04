# Private Browser Client

This module owns framework-neutral, dependency-free browser source. It is composed with exactly one
adapter-owned provider by root tooling and is not published as an npm package.

The provider interface currently requires:

- `framework`: a stable adapter identifier used only in bootstrap metadata;
- `sourceHint(element, {projectApp})`: returns an adapter-owned advisory source hint with a status
  and at most two normalized references.

The client may call that interface but must not recognize Rails, Phoenix, Ruby, or Elixir. Package
providers may depend on this interface during asset composition; the Browser Client never imports
an adapter.

Submission always captures a deterministic breadth-first whole-page structural snapshot. Developers
may add up to eight ordered advisory focus points; the client prefers unique `data-testid`/`id`
anchors, otherwise builds a unique ancestry selector. Each focus includes a conservative provider
hint, outer-to-inner ancestor summaries, and a bounded subtree. Confident provider hints may also
appear on captured snapshot nodes. Focus detail is shared fairly before the page receives the
remaining context allocation. Marked requests use a compact 12 KiB context target: 8 KiB shared
across focus detail and 2 KiB for page surroundings; whole-page requests retain the broader limits.

Each tab reconciles through canonical state polling: 500 ms while connecting or active, 30 seconds
while stable, and bounded one-to-30-second backoff without clearing rendered state after failed reads.
One isolated network failure stays quiet; repeated failures remain visible. Mutations are sent once and
any failed or ambiguous result is reconciled only through a state read.
The single Shadow DOM host survives partial host navigation, remounts after full navigation, and
removes marks whose elements or unique selectors no longer belong to the current DOM.

The lower-left Corner composer uses native controls and one nonduplicative live region across
Connecting, Ready, Working, Finished, Stopped, and Unavailable. An outline-styled **Copy prompt**
action beside **Run with Pi** writes the exact canonical prompt envelope (instruction plus untrusted
context) to the clipboard without submitting; it shares the submission capture path, falls back to the
browser's legacy user-gesture copy path when the modern Clipboard API is unavailable or denied, is
disabled while the instruction is empty or work is active, and reports clipboard failures through the
shared announcer. Opening, collapse/Escape, selection
mode, mark removal/clear, and submission/stop have explicit focus paths; focused host elements can be
marked with Enter or Space. The composer reflows within narrow and 200%-zoom
equivalent viewports and disables motion under the reduced-motion preference. Automated semantics
and current-browser checks apply only to the taskbar-owned Shadow DOM and make no accessibility claim
about the host application.

Capture retains only the contract allowlist, sanitizes URL references, truncates on Unicode
code-point boundaries, and reports every applied bound. A programmatic mount may supply confident
normalized route metadata as `route`; absent or incomplete metadata becomes `null`.
