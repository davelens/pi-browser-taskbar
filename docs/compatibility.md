# Compatibility

`tooling/compatibility.json` is the executable source for compatibility rows. The tables below contain
only rows run by the corresponding compatibility workflows. Each successful row uploads JSON evidence
with exact runtime versions, the built artifact's SHA-256, isolated package installation, and passed
public seams. Versions were checked against stable upstream releases on 2026-07-31; prereleases are
excluded.

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
`pi-browser-taskbar-rails-0.3.0.gem` into an isolated gem home, and rejects a source-workspace
fallback before writing evidence.

Pull requests run the two boundary rows (`Rails 7.1.6 / Ruby 2.7.0` and `Rails 8.1.3.1 / Ruby 4.0.6`).
Pushes to `main` and manual workflow dispatches run the complete release matrix. The complete workflow
is the acceptance and release-blocking Rails claim; a row that has not produced successful evidence
is not supported merely because it appears in prose.

## Phoenix release boundary matrix

| Phoenix | Elixir | Erlang/OTP | LiveView evidence | Evidence scope |
| --- | --- | --- | --- | --- |
| 1.7.24 | 1.11.4 | 23.3.4.20 | 0.17.14 | Generated controller-HEEx/LiveView app, Hex install, boot, route, asset, mutation, annotation provider, supervision, uninstall, development-only behavior |
| 1.8.9 | 1.15.8 | 26.2.5.21 | 1.2.8 | Same public seams at Phoenix 1.8's upstream Elixir floor |
| 1.8.9 | 1.20.2 | 29.0.4 | 1.2.8 | Same public seams on newest stable Elixir and compatible newest Erlang/OTP |

Phoenix 1.7 remains the first-release floor regardless of upstream maintenance status. Each Phoenix
minor uses its newest stable patch at its upstream-declared minimum Elixir with a recorded compatible
OTP patch; newest Phoenix is also run on newest stable Elixir and OTP. Every row generates a fresh
conventional application, installs `pi_browser_taskbar_phoenix-0.3.0.tar` through an isolated signed
Hex repository, and rejects path or source-workspace fallback before recording evidence. Controller
HEEx and LiveView render checks accompany the packaged Phoenix source-annotation provider; LiveView
0.17.14 is the compatible evidence boundary on the fixed Elixir 1.11 floor. Because current hosted
Ubuntu runners have no setup-beam build for OTP 23, that row runs in a digest-pinned standard
Erlang/Elixir Debian Linux image; the Phoenix 1.8 rows continue to use setup-beam directly.

Pull requests run the floor and newest rows (`Phoenix 1.7.24 / Elixir 1.11.4 / OTP 23.3.4.20` and
`Phoenix 1.8.9 / Elixir 1.20.2 / OTP 29.0.4`). Pushes to `main` and manual dispatches run all three
rows. The complete workflow is the acceptance and release-blocking Phoenix claim.

## Adapter floors

| Adapter | Product version | Framework floor | Language floor | Release-blocking platform |
| --- | --- | --- | --- | --- |
| Rails ERB/Turbo | 0.3.0 | Rails 7.1 | MRI Ruby 2.7 | MRI on Linux |
| Phoenix controller-HEEx/LiveView | 0.3.0 | Phoenix 1.7 | Elixir 1.11 | standard Erlang/Elixir runtime on Linux |

Other Ruby engines, nonstandard BEAM runtimes, operating systems, Rails template engines, and older
framework versions are not claimed. The package is development-only on every row. A support expansion
or removal must change the matrix configuration, package metadata, executable checks, and this
validated table together; prose alone cannot expand compatibility.
