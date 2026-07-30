# Private Browser Client

This module owns framework-neutral, dependency-free browser source. It is composed with exactly one
adapter-owned provider by root tooling and is not published as an npm package.

The provider interface currently requires:

- `framework`: a stable adapter identifier used only in bootstrap metadata;
- `sourceHint(element)`: returns adapter-owned advisory source classification.

The client may call that interface but must not recognize Rails, Phoenix, Ruby, or Elixir. Package
providers may depend on this interface during asset composition; the Browser Client never imports
an adapter.

Whole-page submission captures a deterministic breadth-first structural snapshot. It retains only
the contract allowlist, sanitizes URL references, truncates on Unicode code-point boundaries, and
reports every applied bound. A programmatic mount may supply confident normalized route metadata as
`route`; absent or incomplete metadata becomes `null`.
