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
reflow, 200% CSS-zoom reflow emulation, and reduced motion. The human pass below uses real browser
zoom. A deterministic report with artifact SHA-256 values,
engine versions, scope, and scenarios is written to `build/browser-acceptance/automated.json`.

## Human assistive-technology smoke pass

This pass is required before the first release and after a material taskbar interaction change. It
cannot be replaced by or inferred from the automated gate. Use one current stable pairing:

- VoiceOver with Safari on macOS; or
- NVDA with Firefox on Windows.

Use a release-candidate built artifact in each clean example and record the artifact SHA-256 values.
Do not use a workspace path dependency.

1. Start with the launcher collapsed. Read its name, lifecycle status, and **Whole page** scope.
2. Open with the keyboard. Confirm focus moves to **Task instruction** and the panel has a meaningful
   name.
3. Tab through every enabled control in reading order. Confirm focus is visible and each control's
   name, disabled state, expanded state, or pressed state is announced where applicable.
4. Start **Mark element**, move focus to the example card, mark it with Enter or Space, remove it,
   mark it again, then clear all marks. Use Escape once to cancel selection. Confirm focus returns to
   the initiating taskbar control and scope changes are announced once.
5. Submit one whole-page and one focused task. Confirm **Working**, activity, output, **Finished**,
   failure, **Unavailable**, and recovered **Ready** information is understandable without color and
   without duplicate announcements.
6. Stop an active task. Confirm **Stopping**/**Stopped** and the warning that file changes are not
   rolled back are announced.
7. Repeat one idle and one active navigation: Turbo in Rails; controller/LiveView navigation and a
   LiveView patch in Phoenix. Confirm there is still one launcher and no stale marks.
8. At a narrow viewport and 200% browser zoom, traverse and read every control without horizontal
   scrolling or obscured content. Repeat with reduced motion enabled.

Record product version, artifact SHA-256 values, OS, assistive technology and version, browser and
version, both examples exercised, date, tester, result, and sanitized observations. Never record
prompts, browser context, credentials, provider output, or absolute project paths. Until a person
completes and records this checklist, report the manual gate as **pending**; do not claim a pass from
automation. No human pass is recorded in this repository yet.
