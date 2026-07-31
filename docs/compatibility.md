# Compatibility

Compatibility claims are deliberately limited to package metadata floors until the complete release
matrices run. `tooling/compatibility.json` owns the values below; documentation verification compares
it with both package manifests, the root version, and the current CI toolchain.

| Adapter | Product version | Framework floor | Language floor | Current-change CI |
| --- | --- | --- | --- | --- |
| Rails ERB/Turbo | 0.1.0 | Rails 7.1 | MRI Ruby 2.7 | Rails 8.1.3 on Ruby 3.3 |
| Phoenix controller-HEEx/LiveView | 0.1.0 | Phoenix 1.7 | Elixir 1.11 | Phoenix selected by `mix.lock` on Elixir 1.17 / OTP 27 |

The initial target is MRI Ruby and the standard Erlang/Elixir runtime on Linux. Other Ruby engines,
nonstandard BEAM runtimes, operating systems, Rails template engines, and older framework versions
are not claimed. The package is development-only on every supported row.

Issues #38 and #39 own the complete Rails and Phoenix boundary matrices. A future support expansion or
removal must change owning configuration, package metadata, tests, and this checked claim in the same
change; prose alone cannot expand compatibility.
