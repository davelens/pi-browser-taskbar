import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { chromium, firefox, webkit } from "playwright";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const version = fs.readFileSync(path.join(root, "VERSION"), "utf8").trim();
const extracted = fs.mkdtempSync(path.join(os.tmpdir(), "pi-browser-taskbar-browser-"));
const assets = extractPackagedAssets(extracted);
const axe = fs.readFileSync(path.join(root, "node_modules/axe-core/axe.min.js"), "utf8");
let snapshot = readySnapshot("session-1");
let ambiguousSubmission = false;
let lastTaskRequest = null;
const evidence = [];

const server = http.createServer((request, response) => {
  const url = new URL(request.url, "http://localhost");
  const framework = url.searchParams.get("framework") === "rails" ? "rails" : "phoenix";
  if (url.pathname === "/asset.js") return send(response, assets[framework], "text/javascript");
  if (url.pathname === "/axe.js") return send(response, axe, "text/javascript");
  if (url.pathname === "/frame") return send(response, frameHtml(framework), "text/html");
  if (url.pathname === "/") return send(response, harnessHtml(framework), "text/html");
  if (url.pathname === "/dev/pi-browser-taskbar/state") return json(response, snapshot);
  if (url.pathname === "/submitted") return json(response, lastTaskRequest);

  if (url.pathname === "/dev/pi-browser-taskbar/tasks" && request.method === "POST") {
    return readJson(request).then((body) => {
      lastTaskRequest = body;
      snapshot = runningSnapshot("Pi is working", "");
      if (ambiguousSubmission) {
        ambiguousSubmission = false;
        request.socket.destroy();
        return;
      }
      json(response, snapshot, 202);
    });
  }
  if (url.pathname.startsWith("/dev/pi-browser-taskbar/tasks/") && request.method === "DELETE") {
    snapshot = runningSnapshot("Stopping Pi", "partial output", "cancelling");
    return json(response, snapshot, 202);
  }
  if (url.pathname === "/dev/pi-browser-taskbar/session/reset" && request.method === "POST") {
    snapshot = readySnapshot("session-2");
    return json(response, snapshot, 202);
  }
  if (url.pathname === "/control") {
    const state = url.searchParams.get("state");
    if (url.searchParams.get("ambiguous") === "true") ambiguousSubmission = true;
    if (state === "starting") snapshot = { contract_version: 1, session: { id: "session-1", status: "starting", model: null, error: null }, task: null };
    if (state === "ready") snapshot = readySnapshot("session-1");
    if (state === "resetting") snapshot = { contract_version: 1, session: { id: "session-1", status: "resetting", model: "test/fake", error: null }, task: null };
    if (state === "progress") snapshot = runningSnapshot("Running browser_test", "partial output");
    if (state === "completed") snapshot = terminalSnapshot("completed", "Finished output", "Task completed");
    if (state === "failed") snapshot = terminalSnapshot("failed", "", "Task failed", "Check Pi and try again.");
    if (state === "cancelled") snapshot = terminalSnapshot("cancelled", "Stopped output", "Task stopped");
    if (state === "unavailable") snapshot = { contract_version: 1, session: { id: "session-1", status: "unavailable", model: null, error: "Pi is unavailable." }, task: null };
    return json(response, snapshot);
  }
  response.writeHead(404).end();
});

try {
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const engines = { chromium, firefox, webkit };
  const requested = (process.env.PI_BROWSER_TASKBAR_BROWSERS || Object.keys(engines).join(","))
    .split(",").map((name) => name.trim()).filter(Boolean);
  for (const name of requested) assert.ok(engines[name], `unknown browser engine: ${name}`);

  for (const [framework] of Object.entries(assets)) {
    for (const name of requested) {
      snapshot = readySnapshot("session-1");
      ambiguousSubmission = false;
      lastTaskRequest = null;
      const browser = await engines[name].launch({ headless: true });
      try {
        const context = await browser.newContext({ reducedMotion: "reduce" });
        const page = await context.newPage();
        const url = `http://127.0.0.1:${server.address().port}/?framework=${framework}`;
        await page.goto(url);
        await page.waitForFunction(() => document.querySelector("#result")?.textContent !== "RUNNING", null, { timeout: 30_000 });
        const result = await page.locator("#result").textContent();
        assert.equal(result, "CURRENT_BROWSER_PASS", result);
        await runKeyboardFlow(page, framework);
        await runThemePreferenceFlow(context, framework);
        evidence.push({
          framework,
          engine: name,
          version: browser.version(),
          result: "passed",
          checks: [
            "whole-page", "focused", "mark-remove-clear", "progress-output", "stop", "reset-confirmation",
            "unavailable-network-recovery", "cross-tab", framework === "rails" ? "turbo-navigation" : "liveview-navigation-patch",
            "lifecycle-states", "keyboard-focus", "taskbar-owned-axe", "host-theme-sync", "narrow-reflow", "200%-css-zoom-reflow", "reduced-motion",
          ],
        });
        console.log(`${framework} packaged browser/accessibility passed (${name} ${browser.version()})`);
      } finally {
        await browser.close();
      }
    }
  }
  const evidenceDirectory = path.join(root, "build/browser-acceptance");
  fs.mkdirSync(evidenceDirectory, { recursive: true });
  fs.writeFileSync(path.join(evidenceDirectory, "automated.json"), `${JSON.stringify({
    schema: 1,
    product_version: version,
    artifacts: {
      rails: sha256(path.join(root, `build/pi-browser-taskbar-rails-${version}.gem`)),
      phoenix: sha256(path.join(root, `build/pi_browser_taskbar_phoenix-${version}.tar`)),
    },
    scope: "taskbar-owned Shadow DOM only; no host-application accessibility claim",
    complete_matrix: requested.length === Object.keys(engines).length && Object.keys(engines).every((name) => requested.includes(name)),
    runs: evidence,
  }, null, 2)}\n`);
} finally {
  server.close();
  fs.rmSync(extracted, { recursive: true, force: true });
}

async function runKeyboardFlow(page, framework) {
  await page.goto(`http://127.0.0.1:${server.address().port}/control?state=ready`);
  await page.goto(`http://127.0.0.1:${server.address().port}/frame?keyboard&framework=${framework}`);
  await page.waitForFunction(() => globalThis.PiBrowserTaskbar);
  await page.evaluate(async () => {
    const client = globalThis.PiBrowserTaskbar.mount({ autoRefresh: false });
    await client.refresh();
  });

  const taskbar = page.locator("[data-pi-browser-taskbar-host]");
  const toggle = taskbar.locator("[data-toggle]");
  const prompt = taskbar.locator("[data-prompt]");
  const close = taskbar.locator("[data-close]");
  const mark = taskbar.locator("[data-mark]");
  const run = taskbar.locator("[data-run]");
  const reset = taskbar.locator("[data-reset]");

  const toggleBeforeHover = await toggle.boundingBox();
  await toggle.hover();
  const toggleWhileHovered = await toggle.boundingBox();
  assert.equal(toggleWhileHovered.y, toggleBeforeHover.y, "launcher stays still on hover");

  await toggle.focus();
  await page.keyboard.press("Enter");
  await assertShadowFocus(page, "[data-prompt]", "keyboard open moves focus to instruction");

  const closeIcon = close.locator("svg");
  assert.equal(await closeIcon.count(), 1, "close control uses a font-independent icon");
  const closeBox = await close.boundingBox();
  const closeIconBox = await closeIcon.boundingBox();
  const closeCenterOffset = {
    x: Math.abs(closeIconBox.x + closeIconBox.width / 2 - (closeBox.x + closeBox.width / 2)),
    y: Math.abs(closeIconBox.y + closeIconBox.height / 2 - (closeBox.y + closeBox.height / 2)),
  };
  assert.ok(closeCenterOffset.x <= 1 && closeCenterOffset.y <= 1, `close icon is centered: ${JSON.stringify(closeCenterOffset)}`);

  await close.focus();
  await page.keyboard.press("Enter");
  await assertShadowFocus(page, "[data-toggle]", "keyboard close returns focus to launcher");
  await page.keyboard.press("Enter");

  await mark.focus();
  await page.keyboard.press("Enter");
  await page.locator("[data-testid=focus-card]").focus();
  await page.keyboard.press("Enter");
  await assertShadowFocus(page, "[data-prompt]", "keyboard mark returns focus to instruction");
  const remove = taskbar.locator("[data-mark-chip] button");
  await remove.focus();
  await page.keyboard.press("Enter");
  await assertShadowFocus(page, "[data-mark]", "keyboard mark removal returns focus");

  await page.keyboard.press("Enter");
  await page.locator("[data-testid=focus-card]").focus();
  await page.keyboard.press("Enter");
  const clear = taskbar.locator("[data-clear]");
  await clear.focus();
  await page.keyboard.press("Enter");
  await assertShadowFocus(page, "[data-mark]", "keyboard clear returns focus");
  assert.notEqual(await mark.evaluate((element) => getComputedStyle(element).outlineStyle), "none", "focused control has a visible outline");

  await prompt.fill("Keyboard task");
  await run.focus();
  await page.keyboard.press("Enter");
  await page.waitForFunction(() => document.querySelector("[data-pi-browser-taskbar-host]").shadowRoot.querySelector("[data-run]").textContent === "Stop task");
  await page.keyboard.press("Enter");
  await page.waitForFunction(() => document.querySelector("[data-pi-browser-taskbar-host]").shadowRoot.querySelector("[data-run]").textContent === "Stopping…");
  await page.evaluate(async () => {
    await fetch("/control?state=cancelled");
    await globalThis.PiBrowserTaskbar.mount({ autoRefresh: false }).refresh();
  });

  await reset.focus();
  await page.keyboard.press("Enter");
  assert.equal(await reset.textContent(), "Start fresh?", "keyboard exposes inline reset confirmation");
  await page.keyboard.press("Escape");
  assert.equal(await reset.textContent(), "New session", "Escape cancels reset confirmation");
  await assertShadowFocus(page, "[data-reset]", "reset cancellation returns focus");
  await page.keyboard.press("Enter");
  await page.keyboard.press("Enter");
  await page.waitForFunction(() => document.querySelector("[data-pi-browser-taskbar-host]").shadowRoot.querySelector("[data-status]").textContent === "Ready");
}

async function assertShadowFocus(page, selector, message) {
  assert.equal(await page.evaluate((expected) => document.querySelector("[data-pi-browser-taskbar-host]").shadowRoot.activeElement?.matches(expected), selector), true, message);
}

function readySnapshot(id) {
  return { contract_version: 1, session: { id, status: "ready", model: "test/fake", error: null }, task: null };
}

function runningSnapshot(activity, output, status = "running") {
  return {
    contract_version: 1,
    session: { id: "session-1", status: "busy", model: "test/fake", error: null },
    task: { id: "task-1", status, output, output_truncated: false, activity },
  };
}

function terminalSnapshot(status, output, activity = "Task stopped", error = null) {
  return {
    contract_version: 1,
    session: { id: "session-1", status: "ready", model: "test/fake", error: null },
    task: { id: "task-1", status, output, output_truncated: false, activity, error },
  };
}

function send(response, body, type) {
  response.writeHead(200, { "content-type": `${type}; charset=utf-8`, "cache-control": "no-store" });
  response.end(body);
}

function json(response, body, status = 200) {
  response.writeHead(status, { "content-type": "application/json", "cache-control": "no-store" });
  response.end(JSON.stringify(body));
}

function readJson(request) {
  return new Promise((resolve, reject) => {
    let body = "";
    request.setEncoding("utf8");
    request.on("data", (chunk) => { body += chunk; });
    request.on("end", () => {
      try { resolve(JSON.parse(body)); } catch (error) { reject(error); }
    });
    request.on("error", reject);
  });
}

function frameHtml(framework) {
  return `<!doctype html><html><head><style>button { font-family: fantasy !important; } html[data-theme="light"] { color-scheme: light; } html[data-theme="dark"] { color-scheme: dark; }</style></head><body><main data-phx-main data-testid="scenario-whole-page"><section data-testid="scenario-focused-card"><button data-testid="focus-card">Focus card</button></section><nav data-testid="scenario-navigation"><a href="/${framework === "rails" ? "navigation" : "live"}" data-testid="navigation-target">Navigate</a></nav></main><div data-pi-browser-taskbar-bootstrap data-mount-base="/dev/pi-browser-taskbar" data-project-app="demo" data-csrf-token="token"></div><script src="/axe.js"></script><script src="/asset.js?framework=${framework}"></script></body></html>`;
}

function harnessHtml(framework) {
  return `<!doctype html><html><body><pre id="result">RUNNING</pre><script>
  const tabA = window.open("/frame?a&framework=${framework}", "taskbar-tab-a");
  const tabB = window.open("/frame?b&framework=${framework}", "taskbar-tab-b");
  const wait = async (check, label) => {
    for (let count = 0; count < 200; count += 1) {
      if (check()) return;
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    throw new Error("timed out: " + label);
  };
  const check = (value, message) => { if (!value) throw new Error(message); };
  const auditTaskbar = async (win, client, expectedStatus) => {
    const shadow = client.element.shadowRoot;
    const panel = shadow.querySelector("[data-panel]");
    check(panel.getAttribute("aria-label") === "Pi browser task", "named panel");
    check(!panel.textContent.includes("Pi browser task"), "panel omits visible product title");
    check(shadow.querySelector("[data-status]").textContent === expectedStatus, "visible lifecycle status " + expectedStatus);
    check(shadow.querySelectorAll("[aria-live]").length === 1, "single live region");
    check(shadow.querySelector("[data-live]").textContent.trim().length > 0, "meaningful live message");
    check(new Set(Array.from(shadow.querySelectorAll("[id]")).map((element) => element.id)).size === shadow.querySelectorAll("[id]").length, "unique taskbar IDs");
    for (const button of shadow.querySelectorAll("button")) {
      check(Boolean(button.getAttribute("aria-label")?.trim() || button.textContent.trim()), "named native button");
    }
    const prompt = shadow.querySelector("[data-prompt]");
    check(shadow.querySelector('label[for="' + prompt.id + '"]')?.textContent.trim() === "Task instruction", "named textarea");
    check(["true", "false"].includes(shadow.querySelector("[data-toggle]").getAttribute("aria-expanded")), "expanded state");
    check(["true", "false"].includes(shadow.querySelector("[data-mark]").getAttribute("aria-pressed")), "pressed state");
    check(!win.getComputedStyle(shadow.querySelector("[data-toggle]")).fontFamily.includes("fantasy"), "host style isolation");
    const accessibility = await win.axe.run(shadow);
    check(accessibility.violations.length === 0, "taskbar-owned accessibility violations: " + accessibility.violations.map((violation) => violation.id).join(", "));
  };
  (async () => {
    await wait(() => tabA?.PiBrowserTaskbar && tabB?.PiBrowserTaskbar, "tab clients");
    let winA = tabA;
    let winB = tabB;
    let clientA = winA.PiBrowserTaskbar.mount({ autoRefresh: false });
    let clientB = winB.PiBrowserTaskbar.mount({ autoRefresh: false });
    await Promise.all([clientA.refresh(), clientB.refresh()]);
    check(winA.document.querySelectorAll("[data-pi-browser-taskbar-host]").length === 1, "duplicate initial host");

    const shadowA = clientA.element.shadowRoot;
    const toggle = shadowA.querySelector("[data-toggle]");
    check(!clientA.element.hasAttribute("data-light-theme"), "dark theme default");
    check(winA.getComputedStyle(shadowA.querySelector("[data-panel]")).backgroundColor === "rgb(18, 24, 32)", "dark theme surface");
    winA.document.documentElement.setAttribute("data-theme", "light");
    await wait(() => clientA.element.hasAttribute("data-light-theme"), "host light theme sync");
    check(winA.getComputedStyle(shadowA.querySelector("[data-panel]")).backgroundColor === "rgb(246, 248, 251)", "light theme surface");
    toggle.click();
    await auditTaskbar(winA, clientA, "Ready");
    shadowA.querySelector("[data-close]").click();
    winA.document.documentElement.removeAttribute("data-theme");
    winA.document.documentElement.style.colorScheme = "light dark";
    await wait(() => clientA.element.hasAttribute("data-light-theme"), "host color-scheme preference sync");
    winA.document.documentElement.style.colorScheme = "";
    winA.document.documentElement.setAttribute("data-theme", "dark");
    await wait(() => !clientA.element.hasAttribute("data-light-theme"), "host dark theme sync");
    await auditTaskbar(winA, clientA, "Ready");
    toggle.click();
    check(!shadowA.querySelector("[data-panel]").hidden && toggle.hidden, "open composer");
    check(shadowA.activeElement === shadowA.querySelector("[data-prompt]"), "open focus movement");
    const markButton = shadowA.querySelector("[data-mark]");
    const focusedHostElement = winA.document.querySelector("[data-testid=focus-card]");
    markButton.click();
    focusedHostElement.focus();
    focusedHostElement.dispatchEvent(new winA.KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
    check(shadowA.querySelectorAll("[data-mark-chip]").length === 1, "keyboard mark missing");
    await auditTaskbar(winA, clientA, "Ready");
    check(shadowA.activeElement === shadowA.querySelector("[data-prompt]"), "mark focus movement");
    shadowA.querySelector("[data-mark-chip] button").click();
    check(shadowA.activeElement === markButton, "mark removal focus return");
    check(winA.getComputedStyle(markButton).outlineStyle !== "none", "visible keyboard focus");
    markButton.click();
    winA.document.querySelector("[data-testid=focus-card]").click();
    check(shadowA.querySelectorAll("[data-mark-chip]").length === 1, "pointer mark missing");
    shadowA.querySelector("[data-prompt]").dispatchEvent(new winA.KeyboardEvent("keydown", { key: "Escape", bubbles: true, composed: true }));
    check(shadowA.querySelector("[data-panel]").hidden && !toggle.hidden, "Escape closes composer");
    check(shadowA.activeElement === toggle, "close focus return");
    const toggleFocusShadow = winA.getComputedStyle(toggle).boxShadow;
    check(toggleFocusShadow.includes("0px 0px 0px 2px") && toggleFocusShadow.includes("0px 0px 0px 4px"), "launcher dual-contrast focus ring");
    toggle.click();

    await clientA.submit("Focused packaged example task");
    const focusedRequest = await winA.fetch("/submitted").then((response) => response.json());
    check(focusedRequest.context.focus_points.length === 1, "focused packaged request");
    await winA.fetch("/control?state=completed");
    await clientA.refresh();
    shadowA.querySelector("[data-clear]").click();
    check(shadowA.querySelectorAll("[data-mark-chip]").length === 0, "clear all marks");
    check(shadowA.activeElement === markButton, "clear focus return");

    for (const [state, status] of [["starting", "Connecting"], ["ready", "Ready"], ["resetting", "Connecting"], ["progress", "Working"], ["completed", "Finished"], ["failed", "Finished"], ["cancelled", "Stopped"], ["unavailable", "Unavailable"], ["ready", "Ready"]]) {
      await winA.fetch("/control?state=" + state);
      await clientA.refresh();
      await auditTaskbar(winA, clientA, status);
      check(shadowA.querySelector("[data-toggle]").getAttribute("aria-label").includes(status), "launcher accessible lifecycle");
    }

    shadowA.querySelector("[data-mark]").click();
    winA.document.querySelector("[data-testid=focus-card]").click();
    winA.document.querySelector("[data-phx-main]").replaceChildren();
    await wait(() => shadowA.querySelectorAll("[data-mark-chip]").length === 0, "orphan mark removal");
    check(shadowA.querySelectorAll("[data-mark-outline]").length === 0, "orphan outline");

    const narrow = document.createElement("iframe");
    narrow.width = "320";
    narrow.height = "640";
    narrow.src = "/frame?narrow&framework=${framework}";
    document.body.appendChild(narrow);
    await wait(() => narrow.contentWindow?.PiBrowserTaskbar, "narrow taskbar");
    const narrowClient = narrow.contentWindow.PiBrowserTaskbar.mount({ autoRefresh: false });
    await narrowClient.refresh();
    const narrowShadow = narrowClient.element.shadowRoot;
    const narrowToggle = narrowShadow.querySelector("[data-toggle]");
    narrowToggle.click();
    const narrowRect = narrowShadow.querySelector("[data-panel]").getBoundingClientRect();
    check(narrowRect.left >= 0 && narrowRect.right <= narrow.contentDocument.documentElement.clientWidth, "narrow reflow");
    narrowShadow.querySelector("[data-mark]").click();
    narrow.contentDocument.querySelector("[data-testid=focus-card]").click();
    narrowShadow.querySelector("[data-close]").click();
    check(narrowToggle.textContent.includes("1 marked element"), "marked launcher summary");
    narrow.contentDocument.documentElement.style.zoom = "2";
    const zoomedToggleRect = narrowToggle.getBoundingClientRect();
    check(zoomedToggleRect.left >= 0 && zoomedToggleRect.right <= narrow.contentDocument.documentElement.clientWidth, "200% zoom launcher reflow");
    narrowToggle.click();
    const zoomedRect = narrowShadow.querySelector("[data-panel]").getBoundingClientRect();
    check(zoomedRect.left >= 0 && zoomedRect.right <= narrow.contentDocument.documentElement.clientWidth, "200% zoom reflow");
    check(narrowShadow.querySelector("[data-panel]").scrollWidth <= narrowShadow.querySelector("[data-panel]").clientWidth, "200% zoom has no horizontal panel overflow");
    check(narrow.contentWindow.matchMedia("(prefers-reduced-motion: reduce)").matches, "reduced motion preference");
    check(narrow.contentWindow.getComputedStyle(narrowShadow.querySelector("[data-panel]")).animationName === "none", "reduced motion animation");
    narrow.remove();

    const idleBody = winA.document.createElement("body");
    idleBody.innerHTML = "<main>Idle navigation</main>";
    winA.document.dispatchEvent(new winA.CustomEvent("turbo:before-render", { detail: { newBody: idleBody } }));
    winA.document.body.replaceWith(idleBody);
    winA.document.dispatchEvent(new winA.Event("turbo:render"));
    await clientA.refresh();
    check(winA.document.querySelectorAll("[data-pi-browser-taskbar-host]").length === 1, "idle navigation host");
    check(clientA.element.shadowRoot.querySelector("[data-status]").textContent === "Ready", "idle state");

    clientA.reconcile({ fetch: async () => { throw new TypeError("offline"); } });
    await clientA.refresh().catch(() => {});
    check(shadowA.querySelector("[data-status]").textContent === "Ready", "network failure preserves state");
    check(shadowA.querySelector("[data-error]").textContent.includes("Connection lost"), "network recovery message");
    clientA.reconcile({ fetch: winA.fetch.bind(winA) });
    await clientA.refresh();

    await winA.fetch("/control?state=ready&ambiguous=true");
    await clientA.submit("Ambiguous once").catch(() => {});
    const wholePageRequest = await winA.fetch("/submitted").then((response) => response.json());
    check(wholePageRequest.context.focus_points.length === 0, "whole-page packaged request");
    await clientB.refresh();
    check(clientA.element.shadowRoot.querySelector("[data-status]").textContent === "Working", "ambiguous reconciliation");
    check(clientB.element.shadowRoot.querySelector("[data-prompt]").disabled, "cross-context busy admission");

    const activeBody = winA.document.createElement("body");
    activeBody.innerHTML = "<main>Active navigation</main>";
    winA.document.dispatchEvent(new winA.CustomEvent("turbo:before-render", { detail: { newBody: activeBody } }));
    winA.document.body.replaceWith(activeBody);
    winA.document.dispatchEvent(new winA.Event("turbo:render"));
    await clientA.refresh();
    check(winA.document.querySelectorAll("[data-pi-browser-taskbar-host]").length === 1, "active navigation host");
    check(clientA.element.shadowRoot.querySelector("[data-status]").textContent === "Working", "active state");
    if ("${framework}" === "phoenix") {
      winA.document.querySelector("main").innerHTML = '<button data-testid="live-patch">Patched LiveView control</button>';
      winA.document.dispatchEvent(new winA.Event("phx:page-loading-stop"));
      await clientA.refresh();
      check(winA.document.querySelectorAll("[data-pi-browser-taskbar-host]").length === 1, "LiveView navigation/patch host");
      check(clientA.element.shadowRoot.querySelector("[data-status]").textContent === "Working", "LiveView patch active state");
    }

    await fetch("/control?state=progress");
    await Promise.all([clientA.refresh(), clientB.refresh()]);
    check(clientA.element.shadowRoot.querySelector("[data-output]").textContent === "partial output", "progress output A");
    check(clientB.element.shadowRoot.querySelector("[data-activity]").textContent === "Running browser_test", "progress activity B");

    clientB.element.shadowRoot.querySelector("[data-run]").click();
    await wait(() => clientB.element.shadowRoot.querySelector("[data-activity]").textContent === "Stopping Pi", "cross-context cancellation");
    await clientA.refresh();
    check(clientA.element.shadowRoot.querySelector("[data-run]").textContent === "Stopping…", "cancelling state A");
    await fetch("/control?state=cancelled");
    await Promise.all([clientA.refresh(), clientB.refresh()]);
    check(clientA.element.shadowRoot.querySelector("[data-status]").textContent === "Stopped", "terminal A");
    check(clientB.element.shadowRoot.querySelector("[data-output]").textContent === "Stopped output", "terminal output B");

    const reset = clientB.element.shadowRoot.querySelector("[data-reset]");
    reset.click();
    check(reset.textContent === "Start fresh?", "inline reset confirmation");
    reset.click();
    await wait(() => clientB.element.shadowRoot.querySelector("[data-status]").textContent === "Ready" && !clientB.element.shadowRoot.querySelector("[data-output]").textContent, "reset B");
    await clientA.refresh();
    check(!clientA.element.shadowRoot.querySelector("[data-output]").textContent, "reset reconciliation A");

    const oldDocument = winA.document;
    winA.location.href = "/frame?full-navigation";
    await wait(() => winA.document !== oldDocument && winA.PiBrowserTaskbar, "full navigation remount");
    clientA = winA.PiBrowserTaskbar.mount({ autoRefresh: false });
    await clientA.refresh();
    check(winA.document.querySelectorAll("[data-pi-browser-taskbar-host]").length === 1, "full navigation duplicate host");
    check(clientA.element.shadowRoot.querySelector("[data-status]").textContent === "Ready", "full navigation state");
    tabA.close(); tabB.close();
    document.querySelector("#result").textContent = "CURRENT_BROWSER_PASS";
  })().catch((error) => { document.querySelector("#result").textContent = "CURRENT_BROWSER_FAIL: " + error.stack; });
  </script></body></html>`;
}

async function runThemePreferenceFlow(context, framework) {
  const page = await context.newPage();
  try {
    await page.emulateMedia({ colorScheme: "dark" });
    await page.goto(`http://127.0.0.1:${server.address().port}/frame?theme&framework=${framework}`);
    await page.waitForFunction(() => document.querySelector("[data-pi-browser-taskbar-host]"));
    await page.evaluate(() => { document.documentElement.style.colorScheme = "light dark"; });
    await page.waitForFunction(() => !document.querySelector("[data-pi-browser-taskbar-host]").hasAttribute("data-light-theme"));
    await page.emulateMedia({ colorScheme: "light" });
    await page.waitForFunction(() => document.querySelector("[data-pi-browser-taskbar-host]").hasAttribute("data-light-theme"));
    await page.emulateMedia({ colorScheme: "dark" });
    await page.waitForFunction(() => !document.querySelector("[data-pi-browser-taskbar-host]").hasAttribute("data-light-theme"));
  } finally {
    await page.close();
  }
}

function sha256(file) {
  return crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
}

function extractPackagedAssets(directory) {
  const gem = path.join(root, `build/pi-browser-taskbar-rails-${version}.gem`);
  const hex = path.join(root, `build/pi_browser_taskbar_phoenix-${version}.tar`);
  assert.ok(fs.existsSync(gem), `missing built Rails artifact: ${gem}`);
  assert.ok(fs.existsSync(hex), `missing built Phoenix artifact: ${hex}`);

  const railsDirectory = path.join(directory, "rails");
  const phoenixDirectory = path.join(directory, "phoenix");
  fs.mkdirSync(railsDirectory);
  fs.mkdirSync(phoenixDirectory);
  execFileSync("bash", ["-c", "set -o pipefail; tar -xOf \"$1\" data.tar.gz | tar -xz -C \"$2\"", "extract-gem", gem, railsDirectory]);
  execFileSync("bash", ["-c", "set -o pipefail; tar -xOf \"$1\" contents.tar.gz | tar -xz -C \"$2\"", "extract-hex", hex, phoenixDirectory]);

  const paths = {
    rails: path.join(railsDirectory, "lib/pi/browser/taskbar/rails/assets/pi_browser_taskbar.js"),
    phoenix: path.join(phoenixDirectory, "priv/static/pi_browser_taskbar.js"),
  };
  for (const [framework, asset] of Object.entries(paths)) {
    assert.ok(fs.existsSync(asset), `${framework} artifact omitted its Browser Client`);
    assert.ok(asset.startsWith(directory), `${framework} Browser Client was not isolated from the workspace`);
  }
  return Object.fromEntries(Object.entries(paths).map(([framework, asset]) => [framework, fs.readFileSync(asset, "utf8")]));
}
