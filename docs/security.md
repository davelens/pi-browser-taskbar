# Security and remote development

The taskbar is development-only and local by default. The exact normative rules live in the
[Conformance Contract](../contract/docs/index.md#remote-development-access-and-diagnostics).

## Deliberate remote access

An empty `allowed_hosts` list accepts only loopback clients using safe localhost names or addresses.
To use another machine, add the one exact DNS name or IP literal used in the browser and deliberately
bind or proxy the development server so that machine can reach it. The allowlist does not change the
server's listen address.

```text
allowed_hosts = ["devbox.example.test"]
```

Remote plain HTTP is unencrypted. Use it only on a network whose clients and traffic you trust; the
taskbar keeps an in-product warning visible for this mode. Use a trusted HTTPS development proxy or
tunnel instead on any shared, untrusted, or routed network. This mode adds no application-user login,
role, or tenant boundary.

Entries are exact: no scheme, port, path, wildcard, suffix, CIDR, or empty item is accepted. Every
request must also arrive from an allowed client/host combination, mutations keep the framework's
session-bound CSRF protection, and the adapters emit no permissive CORS headers.

## Proxies

Configure trusted proxies in Rails or the Phoenix endpoint/Plug stack before the request reaches the
taskbar. The adapters consume only the framework-normalized host and peer address. They do not read or
interpret `Forwarded` or `X-Forwarded-*` headers themselves, so there is no taskbar-specific proxy
trust switch.

## Diagnostic data

Browser errors use stable codes and safe messages. Adapter logging omits browser context and filters
Rails `prompt` and `context` parameters; raw Pi/provider records and stderr are not logged. The
adapters also avoid logging credentials, inherited environment, absolute project paths, and spawned
commands. Visible page text and URL paths can still be sent to the configured Pi/model provider when
a task is deliberately submitted, so do not use the taskbar with sensitive datasets.
