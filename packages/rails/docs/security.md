# Security and remote development

Pi Browser Taskbar is development-only and local by default. The normative activation, access, CSRF,
configuration, diagnostics, and prompt rules live only in the
[Conformance Contract](../contract/docs/index.md#remote-development-access-and-diagnostics). This
guide explains the threat model without redefining those fields.

## Threat model

The taskbar gives a browser page access to a project-scoped local coding agent. Its relevant threats
are accidental network exposure, cross-site mutation, rendered content masquerading as instruction,
sensitive page data reaching the configured model provider, browser-controlled process settings, and
diagnostics becoming a second disclosure channel. It is not a production administration surface or
an application-user authorization feature.

The packages reduce those risks with native development activation, local-only defaults, exact
server-owned remote opt-in, framework session CSRF, bounded sanitized structural context, a separate
untrusted prompt block, fixed process ownership, and safe diagnostics. Exact requirements and limits
remain in the canonical contract.

## Deliberate remote access

Prefer a local browser. When remote development is necessary, opt in only to the exact browser host
through the adapter's documented native configuration and deliberately expose the development server.
The taskbar setting does not bind or publish that server for you.

Plain HTTP exposes traffic to the network. Use it only on a trusted network and heed the persistent
in-product warning. Prefer a trusted HTTPS development proxy or tunnel on shared, untrusted, or
routed networks. Remote mode adds no host-application login, role, tenant, or transport-encryption
boundary.

## Proxies

Configure trusted proxies in Rails or Phoenix before requests reach the taskbar. The adapters consume
framework-normalized host and peer information rather than creating another forwarding-header trust
model. Follow the canonical contract for accepted host forms and fail-closed combinations.

## Data sent to Pi

A deliberate submission can include visible page text, URL paths, safe structural attributes,
control state, and advisory source hints. It excludes common sensitive and irrelevant browser data,
but it does not detect secrets or PII. Do not use the taskbar with sensitive datasets. Review the
[normalized browser context](../contract/docs/index.md#normalized-browser-context) and
[prompt envelope](../contract/docs/index.md#prompt-envelope) before enabling it for unfamiliar pages.

## Diagnostics and reporting

Browser errors and adapter logs are intentionally bounded and sanitized. When reporting a problem,
provide the stable error code, package/framework versions, and a safe reproduction. Do not attach raw
browser context, prompts, provider records, inherited environment, credentials, or absolute project
paths. See [troubleshooting](troubleshooting.md).
