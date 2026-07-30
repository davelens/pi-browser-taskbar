# Private Browser Client

This module owns framework-neutral, dependency-free browser source. It is composed with exactly one
adapter-owned provider by root tooling and is not published as an npm package.

The provider interface currently requires:

- `framework`: a stable adapter identifier used only in bootstrap metadata;
- `sourceHint(element)`: returns adapter-owned advisory source classification.

The client may call that interface but must not recognize Rails, Phoenix, Ruby, or Elixir. Package
providers may depend on this interface during asset composition; the Browser Client never imports
an adapter.

Submission always captures a deterministic breadth-first whole-page structural snapshot. Developers
may add up to eight ordered advisory focus points; the client prefers unique `data-testid`/`id`
anchors, otherwise builds a unique ancestry selector. Each focus includes conservative provider
classification, outer-to-inner ancestor summaries, and a bounded subtree. Focus detail is shared
fairly before the page receives the remaining context allocation.

Capture retains only the contract allowlist, sanitizes URL references, truncates on Unicode
code-point boundaries, and reports every applied bound. A programmatic mount may supply confident
normalized route metadata as `route`; absent or incomplete metadata becomes `null`.
