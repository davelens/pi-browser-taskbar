import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const assets = {
  phoenix: "packages/phoenix/priv/static/pi_browser_taskbar.js",
  rails: "packages/rails/lib/pi/browser/taskbar/rails/assets/pi_browser_taskbar.js",
};

for (const [framework, relativePath] of Object.entries(assets)) {
  test(`${framework} bootstrap is self-contained and mountable`, () => {
    const sandbox = {};
    const source = fs.readFileSync(path.join(root, relativePath), "utf8");

    vm.runInNewContext(source, sandbox);

    assert.equal(sandbox.PiBrowserTaskbar.framework, framework);
    assert.equal(sandbox.PiBrowserTaskbar.productVersion, "0.1.0");
    assert.equal(sandbox.PiBrowserTaskbar.contractVersion, 1);
    assert.deepEqual(
      JSON.parse(JSON.stringify(sandbox.PiBrowserTaskbar.mount({ mountBase: "/custom" }))),
      {
        contractVersion: 1,
        framework,
        mountBase: "/custom",
        productVersion: "0.1.0",
      },
    );
  });
}

for (const framework of Object.keys(assets)) {
  test(`${framework} Browser Client submits bounded whole-page context and renders completed output`, async () => {
  const document = fakeDocument();
  const visible = document.createElement("p");
  visible.childNodes.push({ nodeType: 3, nodeValue: "🧪".repeat(700) });
  document.body.appendChild(visible);

  const cssHidden = document.createElement("div");
  cssHidden.computedStyle = { display: "block", visibility: "visible", contentVisibility: "visible", opacity: "0" };
  cssHidden.childNodes.push({ nodeType: 3, nodeValue: "hidden secret" });
  document.body.appendChild(cssHidden);

  const editable = document.createElement("div");
  editable.isContentEditable = true;
  editable.childNodes.push({ nodeType: 3, nodeValue: "editable secret" });
  document.body.appendChild(editable);

  const requests = [];
  const snapshots = [
    {
      contract_version: 1,
      session: { id: "opaque-session", status: "busy", model: "test/fake-pi", error: null },
      task: { id: "opaque-task", status: "running", output: "", activity: "Pi is working" },
    },
    {
      contract_version: 1,
      session: { id: "opaque-session", status: "ready", model: "test/fake-pi", error: null },
      task: {
        id: "opaque-task",
        status: "completed",
        output: "Implemented the whole-page request.",
        activity: "Task completed",
      },
    },
  ];

  const sandbox = {
    TextEncoder,
    clearTimeout() {},
    setTimeout() { return 1; },
  };
  const source = fs.readFileSync(path.join(root, assets[framework]), "utf8");
  vm.runInNewContext(source, sandbox);

  const mounted = sandbox.PiBrowserTaskbar.mount({
    autoRefresh: false,
    csrfToken: "native-csrf-token",
    document,
    fetch: async (url, options) => {
      requests.push({ url, options });
      return { ok: true, status: options.method === "POST" ? 202 : 200, json: async () => snapshots.shift() };
    },
    location: {
      href: "http://localhost:4000/cards?page=2&filter=owned",
      origin: "http://localhost:4000",
      pathname: "/cards",
      search: "?page=2&filter=owned",
    },
  });

  await mounted.submit("Explain this page.");
  await mounted.refresh();

  assert.equal(requests[0].url, "/dev/pi-browser-taskbar/tasks");
  assert.equal(requests[0].options.headers["x-csrf-token"], "native-csrf-token");
  const body = JSON.parse(requests[0].options.body);
  assert.equal(body.prompt, "Explain this page.");
  assert.deepEqual(body.context.focus_points, []);
  assert.deepEqual(body.context.location.query_names, ["page", "filter"]);
  assert.ok(Buffer.byteLength(JSON.stringify(body.context.snapshot), "utf8") <= 48 * 1024);
  assert.ok(Buffer.byteLength(body.context.snapshot.children[0].text, "utf8") <= 1000);
  assert.doesNotMatch(JSON.stringify(body.context), /hidden secret|editable secret/);
  assert.equal(mounted.element.shadowRoot.querySelector("[data-output]").textContent, "Implemented the whole-page request.");
  assert.equal(mounted.element.shadowRoot.querySelector("[data-status]").textContent, "Finished");
  });
}

test("Browser Client discards an older state read after task submission", async () => {
  const document = fakeDocument();
  let resolveInitialRefresh;
  const initialRefresh = new Promise((resolve) => { resolveInitialRefresh = resolve; });
  const sandbox = { TextEncoder, clearTimeout() {}, setTimeout() { return 1; } };
  const source = fs.readFileSync(path.join(root, assets.phoenix), "utf8");
  vm.runInNewContext(source, sandbox);

  const mounted = sandbox.PiBrowserTaskbar.mount({
    csrfToken: "native-csrf-token",
    document,
    fetch: async (_url, options) => {
      if (options.method === "GET") return initialRefresh;
      return {
        ok: true,
        status: 202,
        json: async () => ({
          contract_version: 1,
          session: { id: "session", status: "busy", model: "test/fake", error: null },
          task: { id: "task", status: "running", output: "", activity: "Pi is working" },
        }),
      };
    },
    location: { origin: "http://localhost:4000", pathname: "/", search: "" },
  });

  await mounted.submit("Keep the new task state.");
  resolveInitialRefresh({
    ok: true,
    status: 200,
    json: async () => ({
      contract_version: 1,
      session: { id: "session", status: "ready", model: "test/fake", error: null },
      task: null,
    }),
  });
  await new Promise((resolve) => setImmediate(resolve));

  assert.equal(mounted.element.shadowRoot.querySelector("[data-status]").textContent, "Working");
  assert.equal(mounted.element.shadowRoot.querySelector("[data-prompt]").disabled, true);
});

function fakeDocument() {
  class FakeElement {
    constructor(localName = "div") {
      this.localName = localName;
      this.nodeType = 1;
      this.childNodes = [];
      this.children = [];
      this.dataset = {};
      this.hidden = false;
      this.textContent = "";
      this.value = "";
      this.listeners = {};
    }

    addEventListener(name, listener) { this.listeners[name] = listener; }
    appendChild(child) { this.childNodes.push(child); this.children.push(child); return child; }
    attachShadow() { this.shadowRoot = new FakeShadowRoot(); return this.shadowRoot; }
    getAttribute() { return null; }
    hasAttribute() { return false; }
    setAttribute(name, value) { this[name] = String(value); }
  }

  class FakeShadowRoot {
    constructor() {
      this.elements = new Map();
      for (const selector of ["[data-panel]", "[data-toggle]", "[data-status]", "[data-scope]", "[data-prompt]", "[data-run]", "[data-output]", "[data-activity]", "[data-error]"]) {
        this.elements.set(selector, new FakeElement());
      }
    }
    querySelector(selector) { return this.elements.get(selector); }
    set innerHTML(value) { this.markup = value; }
  }

  const body = new FakeElement("body");
  return {
    body,
    defaultView: {
      getComputedStyle(element) {
        return element.computedStyle || { display: "block", visibility: "visible", contentVisibility: "visible" };
      },
    },
    createElement(localName) { return new FakeElement(localName); },
    querySelector() { return null; },
  };
}
