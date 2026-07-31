import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const asset = fs.readFileSync(path.join(root, "packages/phoenix/priv/static/pi_browser_taskbar.js"), "utf8");
let snapshot = readySnapshot("session-1");
let ambiguousSubmission = true;

const server = http.createServer((request, response) => {
  const url = new URL(request.url, "http://localhost");
  if (url.pathname === "/asset.js") return send(response, asset, "text/javascript");
  if (url.pathname === "/frame") return send(response, frameHtml(), "text/html");
  if (url.pathname === "/") return send(response, harnessHtml(), "text/html");
  if (url.pathname === "/dev/pi-browser-taskbar/state") return json(response, snapshot);

  if (url.pathname === "/dev/pi-browser-taskbar/tasks" && request.method === "POST") {
    snapshot = runningSnapshot("Pi is working", "");
    if (ambiguousSubmission) {
      ambiguousSubmission = false;
      request.socket.destroy();
      return;
    }
    return json(response, snapshot, 202);
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
    if (url.searchParams.get("state") === "progress") snapshot = runningSnapshot("Running browser_test", "partial output");
    if (url.searchParams.get("state") === "cancelled") snapshot = terminalSnapshot("cancelled", "Stopped output");
    return json(response, snapshot);
  }
  response.writeHead(404).end();
});

try {
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const browser = findBrowser();
  assert.ok(browser, "current Chrome/Chromium executable is required");
  const url = `http://127.0.0.1:${server.address().port}/`;
  const result = await run(browser, [
    "--headless=new",
    "--no-sandbox",
    "--disable-gpu",
    "--disable-dev-shm-usage",
    "--dump-dom",
    "--virtual-time-budget=10000",
    url,
  ]);
  assert.equal(result.code, 0, result.stderr);
  assert.match(result.stdout, /CURRENT_BROWSER_PASS/u, `${result.stdout}\n${result.stderr}`);
  console.log(`current-browser navigation/reconciliation passed (${path.basename(browser)})`);
} finally {
  server.close();
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

function terminalSnapshot(status, output) {
  return {
    contract_version: 1,
    session: { id: "session-1", status: "ready", model: "test/fake", error: null },
    task: { id: "task-1", status, output, output_truncated: false, activity: "Task stopped" },
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

function frameHtml() {
  return `<!doctype html><html><body><main data-phx-main><button data-testid="focus">Focus</button></main><div data-pi-browser-taskbar-bootstrap data-mount-base="/dev/pi-browser-taskbar" data-project-app="demo" data-csrf-token="token"></div><script src="/asset.js"></script></body></html>`;
}

function harnessHtml() {
  return `<!doctype html><html><body><pre id="result">RUNNING</pre><script>
  const tabA = window.open("/frame?a", "taskbar-tab-a");
  const tabB = window.open("/frame?b", "taskbar-tab-b");
  const wait = async (check, label) => {
    for (let count = 0; count < 200; count += 1) {
      if (check()) return;
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    throw new Error("timed out: " + label);
  };
  const check = (value, message) => { if (!value) throw new Error(message); };
  (async () => {
    await wait(() => tabA?.PiBrowserTaskbar && tabB?.PiBrowserTaskbar, "tab clients");
    let winA = tabA;
    let winB = tabB;
    let clientA = winA.PiBrowserTaskbar.mount({ autoRefresh: false });
    let clientB = winB.PiBrowserTaskbar.mount({ autoRefresh: false });
    await Promise.all([clientA.refresh(), clientB.refresh()]);
    check(winA.document.querySelectorAll("[data-pi-browser-taskbar-host]").length === 1, "duplicate initial host");

    const shadowA = clientA.element.shadowRoot;
    shadowA.querySelector("[data-mark]").click();
    winA.document.querySelector("[data-testid=focus]").click();
    check(shadowA.querySelectorAll("[data-mark-chip]").length === 1, "mark missing");
    winA.document.querySelector("[data-phx-main]").replaceChildren();
    await wait(() => shadowA.querySelectorAll("[data-mark-chip]").length === 0, "orphan mark removal");
    check(shadowA.querySelectorAll("[data-mark-outline]").length === 0, "orphan outline");

    const idleBody = winA.document.createElement("body");
    idleBody.innerHTML = "<main>Idle navigation</main>";
    winA.document.dispatchEvent(new winA.CustomEvent("turbo:before-render", { detail: { newBody: idleBody } }));
    winA.document.body.replaceWith(idleBody);
    winA.document.dispatchEvent(new winA.Event("turbo:render"));
    await clientA.refresh();
    check(winA.document.querySelectorAll("[data-pi-browser-taskbar-host]").length === 1, "idle navigation host");
    check(clientA.element.shadowRoot.querySelector("[data-status]").textContent === "Ready", "idle state");

    await clientA.submit("Ambiguous once").catch(() => {});
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
    reset.click(); reset.click();
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

function findBrowser() {
  const candidates = [process.env.PI_BROWSER_TASKBAR_BROWSER, "/usr/bin/google-chrome", "/usr/bin/chromium", "/usr/bin/chromium-browser"].filter(Boolean);
  return candidates.find((candidate) => fs.existsSync(candidate));
}

function run(command, args) {
  return new Promise((resolve) => {
    const child = spawn(command, args, { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.on("close", (code) => resolve({ code, stdout, stderr }));
  });
}
