# Compatibility

`tooling/compatibility.json` is the executable source for compatibility rows. The Rails support table
below contains only rows run by `.github/workflows/rails-compatibility.yml`; each successful row
uploads JSON evidence containing the exact runtime versions, built-gem SHA-256, isolated installation
check, Puma mode, and passed public seams. Versions were checked against stable upstream releases on
2026-07-31; prereleases are excluded.

## Rails release boundary matrix

| Rails | MRI Ruby | Puma mode | Evidence scope |
| --- | --- | --- | --- |
| 7.1.6 | 2.7.0 | single | Generated ERB app, boot, route, asset, mutation, annotation, uninstall, production-disabled behavior |
| 7.2.3.2 | 3.1.0 | clustered | Same public seams with two Puma workers |
| 8.0.5.1 | 3.2.0 | preloaded | Same public seams with a preloaded Puma cluster |
| 8.1.3.1 | 3.2.0 | phased | Same public seams across a Puma phased restart |
| 8.1.3.1 | 4.0.6 | single | Same public seams on the newest stable MRI Ruby |

Rails 7.1 is the first-release floor even though its upstream maintenance status may change. Each
Rails minor uses its newest stable patch and its upstream-declared minimum Ruby; newest Rails is also
run on newest stable Ruby. Every row generates a fresh conventional application, installs the built
`pi-browser-taskbar-rails-0.1.0.gem` into an isolated gem home, and rejects a source-workspace
fallback before writing evidence.

Pull requests run the two boundary rows (`Rails 7.1.6 / Ruby 2.7.0` and `Rails 8.1.3.1 / Ruby 4.0.6`).
Pushes to `main` and manual workflow dispatches run the complete release matrix. The complete workflow
is the acceptance and release-blocking Rails claim; a row that has not produced successful evidence
is not supported merely because it appears in prose.

## Adapter floors

| Adapter | Product version | Framework floor | Language floor | Release-blocking platform |
| --- | --- | --- | --- | --- |
| Rails ERB/Turbo | 0.1.0 | Rails 7.1 | MRI Ruby 2.7 | MRI on Linux |
| Phoenix controller-HEEx/LiveView | 0.1.0 | Phoenix 1.7 | Elixir 1.11 | Standard Erlang/Elixir runtime on Linux |

Issue #39 owns the complete Phoenix boundary matrix. Until that matrix runs, the Phoenix entries are
metadata floors rather than a row-by-row support table; ordinary monorepo CI currently uses
Elixir 1.17 / OTP 27. Other Ruby engines, nonstandard BEAM
runtimes, operating systems, Rails template engines, and older framework versions are not claimed.
The package is development-only on every row.

A support expansion or removal must change the matrix configuration, package metadata, executable
checks, and this validated table together; prose alone cannot expand compatibility.
