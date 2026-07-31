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
through an application-prefixed package-owned Phoenix session/CSRF pipeline, one root-layout
bootstrap, installation metadata, and the uninstall seam. The installer also enables development
HEEx debug annotations. In non-development builds the dependency-free stub contributes no routes,
assets, or runtime behavior.

The packaged clean-host fixture proves idempotent update, conflict refusal, development mutation,
production/test compilation without the package, and reversible uninstall through the same public
Mix task. Remove an installation with:

```sh
MIX_ENV=dev mix pi_browser_taskbar.install --uninstall
```

A standalone packaged example application will replace the generated clean-host fixture when the
cross-adapter example milestone adds Rails parity; no example-only runtime behavior belongs here.
