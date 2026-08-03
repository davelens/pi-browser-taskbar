# Browser and accessibility acceptance

The WCAG 2.2 AA target is limited to the taskbar-owned Shadow DOM. It is not an accessibility claim
for the Rails or Phoenix host page.

## Automated gate

Install the pinned test tooling and browser engines, then run the clean-checkout gate:

```sh
npm ci
npx playwright install --with-deps chromium firefox webkit
bin/verify
```

`bin/verify` builds both artifacts before browser acceptance. The browser runner extracts the
Browser Client from the built gem and Hex archive into an isolated temporary directory; it never
loads Browser Client or committed adapter asset source. For both equivalent packaged-example
surfaces it runs Chromium, Firefox, and WebKit through whole-page and focused submissions, mark
removal and clear, progress/output, stop, unavailable and network recovery, cross-tab reconciliation,
every material lifecycle state, and framework navigation. Rails covers
Turbo replacement and full navigation. Phoenix covers controller-to-LiveView navigation and a live
DOM patch.

Each row also checks taskbar-owned axe results, native names and states, non-color lifecycle text, one
polite atomic live region, keyboard marking and focus return, visible focus, desktop and narrow
reflow, 200% CSS-zoom reflow emulation, and reduced motion. A deterministic report with artifact
SHA-256 values, engine versions, scope, and scenarios is written to
`build/browser-acceptance/automated.json`.
