# Phoenix example

The first Phoenix reference flow is exercised from a clean conventional host fixture by the
package installer and shared black-box conformance tests. It uses only these public package seams:

```elixir
# development-only dependency
{:pi_browser_taskbar_phoenix, "~> 0.1.0", only: :dev, runtime: false}
```

```sh
MIX_ENV=dev mix pi_browser_taskbar.install
```

The generated host module contributes one supervised child before the endpoint, one router mount
through a package-owned Phoenix session/CSRF pipeline, and one root-layout bootstrap. In non-development
builds its dependency-free stub contributes none of those concerns.

A standalone packaged example application will replace the generated clean-host fixture when the
cross-adapter example milestone adds Rails parity; no example-only runtime behavior belongs here.
