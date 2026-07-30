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
  const visible = document.createElement("a");
  visible.setAttribute("id", "checkout");
  visible.setAttribute("class", "btn btn-primary");
  visible.setAttribute("role", "button");
  visible.setAttribute("aria-label", "  Chèque\u0301out  ");
  visible.setAttribute("href", "/checkout?token=secret&step=2#payment");
  visible.setAttribute("name", "checkout");
  visible.setAttribute("type", "submit");
  visible.setAttribute("placeholder", " Optional   note ");
  visible.setAttribute("data-testid", "checkout-button");
  visible.setAttribute("data-secret", "must not be captured");
  visible.setAttribute("aria-expanded", "true");
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

  for (const [tag, secret] of [["script", "script secret"], ["style", "style secret"], ["meta", "metadata secret"], ["textarea", "textarea secret"], ["select", "selected secret"], ["iframe", "iframe secret"]]) {
    const element = document.createElement(tag);
    element.childNodes.push({ nodeType: 3, nodeValue: secret });
    document.body.appendChild(element);
  }

  const input = document.createElement("input");
  input.value = "form value secret";
  input.disabled = false;
  input.checked = true;
  input.required = true;
  input.setAttribute("type", "checkbox");
  input.setAttribute("value", "attribute value secret");
  document.body.appendChild(input);

  const label = document.createElement("span");
  label.setAttribute("id", "labelled-name");
  label.childNodes.push({ nodeType: 3, nodeValue: "Labelled action" });
  document.body.appendChild(label);
  const labelledButton = document.createElement("button");
  labelledButton.setAttribute("aria-labelledby", "labelled-name");
  document.body.appendChild(labelledButton);

  const hiddenInput = document.createElement("input");
  hiddenInput.setAttribute("type", "hidden");
  hiddenInput.value = "hidden input secret";
  document.body.appendChild(hiddenInput);

  let deepParent = document.body;
  for (let depth = 0; depth < 14; depth += 1) {
    const child = document.createElement("div");
    deepParent.appendChild(child);
    deepParent = child;
  }

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
    URL,
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
      href: "http://user:password@localhost:4000/cards?page=2&filter=owned#secret",
      origin: "http://localhost:4000",
      pathname: "/cards",
      search: "?page=2&filter=owned",
    },
    route: {
      method: "get",
      pattern: "/cards/:id",
      handler: "DemoWeb.CardLive.Show",
      action: "show",
    },
  });

  await mounted.submit("Explain this page.");
  await mounted.refresh();

  assert.equal(requests[0].url, "/dev/pi-browser-taskbar/tasks");
  assert.equal(requests[0].options.headers["x-csrf-token"], "native-csrf-token");
  const body = JSON.parse(requests[0].options.body);
  assert.equal(body.prompt, "Explain this page.");
  assert.deepEqual(body.context.focus_points, []);
  assert.deepEqual(body.context.location, {
    origin: "http://localhost:4000",
    path: "/cards",
    query_names: ["page", "filter"],
  });
  assert.deepEqual(body.context.route, {
    method: "GET",
    pattern: "/cards/:id",
    handler: "DemoWeb.CardLive.Show",
    action: "show",
  });
  assert.ok(Buffer.byteLength(JSON.stringify(body.context.snapshot), "utf8") <= 48 * 1024);
  assert.ok(Buffer.byteLength(body.context.snapshot.children[0].text, "utf8") <= 1000);
  assert.deepEqual(body.context.snapshot.children[0].classes, ["btn", "btn-primary"]);
  assert.equal(body.context.snapshot.children[0].name, "Chèque\u0301out".normalize("NFC"));
  assert.deepEqual(body.context.snapshot.children[0].attributes, {
    name: "checkout",
    type: "submit",
    placeholder: "Optional note",
    "data-testid": "checkout-button",
  });
  assert.deepEqual(body.context.snapshot.children[0].state, { expanded: true });
  assert.deepEqual(body.context.snapshot.children[0].href, {
    origin: "http://localhost:4000",
    path: "/checkout",
    query_names: ["token", "step"],
  });
  const inputNode = body.context.snapshot.children.find((node) => node.tag === "input");
  assert.deepEqual(inputNode.state, { disabled: false, checked: true, required: true });
  const buttonNode = body.context.snapshot.children.find((node) => node.tag === "button");
  assert.equal(buttonNode.name, "Labelled action");
  assert.doesNotMatch(JSON.stringify(body.context), /secret|editable|selected|raw_html|data-secret/);
  assert.deepEqual(body.context.truncation, [{ section: "page", reasons: ["depth", "string"] }]);
  assert.equal(mounted.element.shadowRoot.querySelector("[data-output]").textContent, "Implemented the whole-page request.");
  assert.equal(mounted.element.shadowRoot.querySelector("[data-status]").textContent, "Finished");
  await assert.rejects(mounted.submit("🧪".repeat(1001)), /at most 4000 bytes/);
  assert.equal(requests.length, 2);
  });
}

test("Browser Client retains page nodes in breadth-first order when byte-truncated", async () => {
  const document = fakeDocument();
  const earlyBranch = document.createElement("section");
  earlyBranch.setAttribute("id", "early");
  for (let index = 0; index < 60; index += 1) {
    const paragraph = document.createElement("p");
    paragraph.childNodes.push({ nodeType: 3, nodeValue: `${index}:`.padEnd(1000, "x") });
    earlyBranch.appendChild(paragraph);
  }
  document.body.appendChild(earlyBranch);
  const laterSibling = document.createElement("aside");
  laterSibling.setAttribute("id", "later-sibling");
  document.body.appendChild(laterSibling);

  let requestBody;
  const sandbox = { TextEncoder, URL, clearTimeout() {}, setTimeout() { return 1; } };
  const source = fs.readFileSync(path.join(root, assets.phoenix), "utf8");
  vm.runInNewContext(source, sandbox);
  const unicodePath = `/${"🧪".repeat(600)}`;
  const mounted = sandbox.PiBrowserTaskbar.mount({
    autoRefresh: false,
    csrfToken: "token",
    document,
    fetch: async (_url, options) => {
      requestBody = JSON.parse(options.body);
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
    location: {
      href: `http://localhost:4000${unicodePath}`,
      origin: "http://localhost:4000",
      pathname: unicodePath,
      search: "",
    },
  });

  await mounted.submit("Keep broad structure.");

  assert.equal(requestBody.context.snapshot.children[1].id, "later-sibling");
  assert.ok(Buffer.byteLength(requestBody.context.location.path, "utf8") <= 2048);
  assert.doesNotMatch(requestBody.context.location.path, /%(?:[0-9a-f])?$/iu);
  assert.deepEqual(requestBody.context.truncation, [{ section: "page", reasons: ["bytes", "string"] }]);
});

test("Browser Client discards an older state read after task submission", async () => {
  const document = fakeDocument();
  let resolveInitialRefresh;
  const initialRefresh = new Promise((resolve) => { resolveInitialRefresh = resolve; });
  const sandbox = { TextEncoder, URL, clearTimeout() {}, setTimeout() { return 1; } };
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
      this.attributes = new Map();
      this.classList = [];
    }

    addEventListener(name, listener) { this.listeners[name] = listener; }
    appendChild(child) { this.childNodes.push(child); this.children.push(child); child.parentElement = this; return child; }
    attachShadow() { this.shadowRoot = new FakeShadowRoot(); return this.shadowRoot; }
    getAttribute(name) { return this.attributes.get(name) ?? null; }
    hasAttribute(name) { return this.attributes.has(name); }
    setAttribute(name, value) {
      this.attributes.set(name, String(value));
      if (name === "class") this.classList = String(value).split(/\s+/u).filter(Boolean);
      else this[name] = String(value);
    }
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
    getElementById(id) {
      const queue = [body];
      while (queue.length > 0) {
        const element = queue.shift();
        if (element.getAttribute?.("id") === id) return element;
        queue.push(...element.children);
      }
      return null;
    },
    querySelector() { return null; },
  };
}
