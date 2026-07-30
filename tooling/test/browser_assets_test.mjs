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

for (const framework of Object.keys(assets)) {
  test(`${framework} Browser Client marks, removes, clears, and submits up to eight advisory focuses`, async () => {
    const document = fakeDocument();
    const container = document.createElement("section");
    container.setAttribute("id", "cards");
    document.body.appendChild(container);
    const fallbackFirst = document.createElement("button");
    const fallbackSecond = document.createElement("button");
    container.appendChild(fallbackFirst);
    container.appendChild(fallbackSecond);
    const stable = Array.from({ length: 8 }, (_value, index) => {
      const element = document.createElement("article");
      element.setAttribute("data-testid", `card-${index + 1}`);
      element.childNodes.push({ nodeType: 3, nodeValue: `Card ${index + 1}` });
      document.body.appendChild(element);
      return element;
    });

    const requests = [];
    const sandbox = { TextEncoder, URL, clearTimeout() {}, setTimeout() { return 1; } };
    vm.runInNewContext(fs.readFileSync(path.join(root, assets[framework]), "utf8"), sandbox);
    const mounted = sandbox.PiBrowserTaskbar.mount({
      autoRefresh: false,
      csrfToken: "token",
      document,
      fetch: async (_url, options) => {
        requests.push(JSON.parse(options.body));
        return {
          ok: true,
          status: 202,
          json: async () => ({ contract_version: 1, session: { id: "session", status: "ready" }, task: null }),
        };
      },
      location: { origin: "http://localhost:4000", pathname: "/cards", search: "" },
    });
    const shadow = mounted.element.shadowRoot;
    const mark = shadow.querySelector("[data-mark]");

    mark.dispatchEvent({ type: "click" });
    assert.equal(mark.getAttribute("aria-pressed"), "true");
    document.dispatch("pointermove", fallbackSecond);
    assert.equal(shadow.querySelector("[data-hover-outline]").hidden, false);
    document.dispatch("keydown", document.body, { key: "Escape" });
    assert.equal(mark.getAttribute("aria-pressed"), "false");
    assert.equal(shadow.querySelector("[data-hover-outline]").hidden, true);

    select(mark, document, fallbackSecond);
    assert.equal(shadow.querySelector("[data-marks]").children.length, 1);
    assert.equal(shadow.querySelector("[data-overlays]").children.length, 1);
    assert.match(shadow.querySelector("[data-scope]").textContent, /^1 marked element/);
    await mounted.submit("Improve this control.");
    assert.equal(requests[0].context.focus_points.length, 1);
    assert.match(requests[0].context.focus_points[0].selector, /^\[id="cards"\] > button:nth-of-type\(2\)$/u);
    assert.deepEqual(requests[0].context.focus_points[0].source, {
      status: "unavailable",
      references: [],
    });
    assert.deepEqual(requests[0].context.focus_points[0].ancestors.map((node) => node.tag), ["body", "section"]);
    assert.equal(requests[0].context.snapshot.tag, "body");

    select(mark, document, fallbackSecond);
    assert.equal(shadow.querySelector("[data-marks]").children.length, 1);
    shadow.querySelector("[data-marks]").children[0].children[1].dispatchEvent({ type: "click" });
    assert.equal(shadow.querySelector("[data-marks]").children.length, 0);
    assert.equal(shadow.querySelector("[data-scope]").textContent, "Whole page · bounded structural context");

    stable.forEach((element) => select(mark, document, element));
    assert.equal(shadow.querySelector("[data-marks]").children.length, 8);
    assert.equal(mark.disabled, true);
    await mounted.submit("Improve all cards.");
    assert.deepEqual(
      requests[1].context.focus_points.map((point) => point.selector),
      stable.map((_element, index) => `[data-testid="card-${index + 1}"]`),
    );
    shadow.querySelector("[data-clear]").dispatchEvent({ type: "click" });
    assert.equal(shadow.querySelector("[data-marks]").children.length, 0);
    assert.equal(shadow.querySelector("[data-scope]").textContent, "Whole page · bounded structural context");
  });
}

test("Rails ERB hints cover layouts, partials, collections, caching, helpers, Turbo updates, external templates, and missing evidence", async () => {
  const document = fakeDocument();
  const cases = [];

  cases.push(annotatedRailsElement(document, "app/views/layouts/application.html.erb", "layout"));

  const nested = document.createElement("section");
  document.body.appendChild(nested);
  nested.appendChild(railsComment("BEGIN", "app/views/cards/index.html.erb"));
  const partialHost = document.createElement("article");
  nested.appendChild(partialHost);
  nested.appendChild(railsComment("END", "app/views/cards/index.html.erb"));
  partialHost.appendChild(railsComment("BEGIN", "app/views/cards/_card.html.erb"));
  const nestedTarget = document.createElement("button");
  nestedTarget.setAttribute("data-testid", "nested-partial");
  partialHost.appendChild(nestedTarget);
  partialHost.appendChild(railsComment("END", "app/views/cards/_card.html.erb"));
  cases.push(nestedTarget);

  annotatedRailsElement(document, "app/views/cards/_card.html.erb", "collection-first");
  cases.push(annotatedRailsElement(document, "app/views/cards/_card.html.erb", "collection-second"));
  cases.push(annotatedRailsElement(document, "app/views/cards/_cached_card.html.erb", "cached-fragment"));
  cases.push(annotatedRailsElement(document, "app/views/cards/show.html.erb", "helper-generated"));

  const externalHost = document.createElement("section");
  document.body.appendChild(externalHost);
  externalHost.appendChild(railsComment("BEGIN", "app/views/cards/show.html.erb"));
  const externalInner = document.createElement("div");
  externalHost.appendChild(externalInner);
  externalHost.appendChild(railsComment("END", "app/views/cards/show.html.erb"));
  externalInner.appendChild(railsComment("BEGIN", "/gems/library/app/views/widgets/_widget.html.erb"));
  const externalTarget = document.createElement("button");
  externalTarget.setAttribute("data-testid", "dependency-template");
  externalInner.appendChild(externalTarget);
  externalInner.appendChild(railsComment("END", "/gems/library/app/views/widgets/_widget.html.erb"));
  cases.push(externalTarget);

  const missing = document.createElement("button");
  missing.setAttribute("data-testid", "missing-annotations");
  document.body.appendChild(missing);
  cases.push(missing);

  let requestBody;
  const sandbox = { TextEncoder, URL, clearTimeout() {}, setTimeout() { return 1; } };
  vm.runInNewContext(fs.readFileSync(path.join(root, assets.rails), "utf8"), sandbox);
  const mounted = sandbox.PiBrowserTaskbar.mount({
    autoRefresh: false,
    csrfToken: "token",
    document,
    fetch: async (_url, options) => {
      requestBody = JSON.parse(options.body);
      return {
        ok: true,
        status: 202,
        json: async () => ({ contract_version: 1, session: { id: "session", status: "ready" }, task: null }),
      };
    },
    location: { origin: "http://localhost:3000", pathname: "/cards", search: "" },
  });

  const turboTarget = annotatedRailsElement(document, "app/views/cards/_card.html.erb", "turbo-update");
  cases.splice(5, 0, turboTarget);
  const mark = mounted.element.shadowRoot.querySelector("[data-mark]");
  cases.forEach((element) => select(mark, document, element));
  await mounted.submit("Use conservative Rails template evidence.");

  const sources = requestBody.context.focus_points.map((point) => point.source);
  assert.deepEqual(sources.slice(0, 6), [
    railsSource("app/views/layouts/application.html.erb"),
    railsSource("app/views/cards/_card.html.erb"),
    railsSource("app/views/cards/_card.html.erb"),
    railsSource("app/views/cards/_cached_card.html.erb"),
    railsSource("app/views/cards/show.html.erb"),
    railsSource("app/views/cards/_card.html.erb"),
  ]);
  assert.deepEqual(sources.slice(6), [
    { status: "external", references: [] },
    { status: "unavailable", references: [] },
  ]);
  assert.ok(sources.flatMap((source) => source.references).every((reference) =>
    reference.precision === "template" && !("line" in reference) && !("symbol" in reference)));
  assert.doesNotMatch(JSON.stringify(requestBody.context), /\/gems\/library|BEGIN|END/u);
});

test("Rails ERB hints reject malformed, overlapping, displaced, traversing, and vendored boundaries without outer fallback", async () => {
  const document = fakeDocument();
  const cases = [];

  const malformed = document.createElement("section");
  document.body.appendChild(malformed);
  malformed.appendChild(comment(" BEGIN app/views/cards/_card.html.erb extra\n"));
  const malformedTarget = document.createElement("button");
  malformedTarget.setAttribute("data-testid", "malformed");
  malformed.appendChild(malformedTarget);
  malformed.appendChild(railsComment("END", "app/views/cards/_card.html.erb"));
  cases.push(malformedTarget);

  const overlapping = document.createElement("section");
  document.body.appendChild(overlapping);
  overlapping.appendChild(railsComment("BEGIN", "app/views/cards/index.html.erb"));
  overlapping.appendChild(railsComment("BEGIN", "app/views/cards/_card.html.erb"));
  const overlappingTarget = document.createElement("button");
  overlappingTarget.setAttribute("data-testid", "overlapping");
  overlapping.appendChild(overlappingTarget);
  overlapping.appendChild(railsComment("END", "app/views/cards/index.html.erb"));
  overlapping.appendChild(railsComment("END", "app/views/cards/_card.html.erb"));
  cases.push(overlappingTarget);

  const repaired = document.createElement("section");
  document.body.appendChild(repaired);
  repaired.appendChild(railsComment("BEGIN", "app/views/layouts/application.html.erb"));
  const repairedHost = document.createElement("table");
  repaired.appendChild(repairedHost);
  repairedHost.appendChild(railsComment("BEGIN", "app/views/cards/_row.html.erb"));
  const repairedTarget = document.createElement("button");
  repairedTarget.setAttribute("data-testid", "browser-repaired");
  repairedHost.appendChild(repairedTarget);
  repaired.appendChild(railsComment("END", "app/views/cards/_row.html.erb"));
  repaired.appendChild(railsComment("END", "app/views/layouts/application.html.erb"));
  cases.push(repairedTarget);

  cases.push(annotatedRailsElement(document, "../outside/app/views/cards/_card.html.erb", "traversal"));
  cases.push(annotatedRailsElement(document, "vendor/bundle/ruby/gems/demo/app/views/_demo.html.erb", "vendored"));

  let requestBody;
  const sandbox = { TextEncoder, URL, clearTimeout() {}, setTimeout() { return 1; } };
  vm.runInNewContext(fs.readFileSync(path.join(root, assets.rails), "utf8"), sandbox);
  const mounted = sandbox.PiBrowserTaskbar.mount({
    autoRefresh: false,
    csrfToken: "token",
    document,
    fetch: async (_url, options) => {
      requestBody = JSON.parse(options.body);
      return {
        ok: true,
        status: 202,
        json: async () => ({ contract_version: 1, session: { id: "session", status: "ready" }, task: null }),
      };
    },
    location: { origin: "http://localhost:3000", pathname: "/cards", search: "" },
  });
  const mark = mounted.element.shadowRoot.querySelector("[data-mark]");
  cases.forEach((element) => select(mark, document, element));
  await mounted.submit("Classify unsafe Rails annotation evidence.");

  assert.deepEqual(
    requestBody.context.focus_points.map((point) => point.source),
    [
      { status: "ambiguous", references: [] },
      { status: "ambiguous", references: [] },
      { status: "ambiguous", references: [] },
      { status: "external", references: [] },
      { status: "external", references: [] },
    ],
  );
  assert.doesNotMatch(JSON.stringify(requestBody.context), /outside|vendor\/bundle|_row\.html\.erb/u);
});

function annotatedRailsElement(document, path, testId) {
  const wrapper = document.createElement("section");
  document.body.appendChild(wrapper);
  wrapper.appendChild(railsComment("BEGIN", path));
  const element = document.createElement("button");
  element.setAttribute("data-testid", testId);
  wrapper.appendChild(element);
  wrapper.appendChild(railsComment("END", path));
  return element;
}

function railsComment(kind, path) {
  return comment(kind === "BEGIN" ? ` ${kind} ${path}\n` : ` ${kind} ${path} `);
}

function railsSource(path) {
  return {
    status: "available",
    references: [{ role: "template", path, precision: "template" }],
  };
}

test("Phoenix HEEx hints stay conservative across controller, LiveView, navigation, and DOM patch evidence", async () => {
  const document = fakeDocument();
  const cases = [];

  cases.push(annotatedPhoenixElement(document, {
    comments: [" <DemoWeb.PageHTML.home> lib/demo_web/controllers/page_html/home.html.heex:1 (demo) "],
    location: "12",
    testId: "controller-template",
  }));
  cases.push(annotatedPhoenixElement(document, {
    comments: [
      " <DemoWeb.CardLive.render> lib/demo_web/live/card_live.ex:10 (demo) ",
      " @caller lib/demo_web/live/card_live.ex:30 (demo) ",
      " <DemoWeb.CoreComponents.button> lib/demo_web/components/core_components.ex:200 (demo) ",
    ],
    location: "218",
    testId: "live-component",
  }));
  cases.push(annotatedPhoenixElement(document, {
    comments: [
      " <DemoWeb.CardLive.render> lib/demo_web/live/card_live.ex:10 (demo) ",
      " @caller lib/demo_web/live/card_live.ex:15 (demo) ",
      " <DemoWeb.CoreComponents.button> lib/demo_web/components/core_components.ex:200 (demo) ",
      " </DemoWeb.CoreComponents.button> ",
    ],
    location: "44",
    testId: "closed-component",
  }));
  cases.push(annotatedPhoenixElement(document, {
    comments: [" <DemoWeb.CardLive.render> lib/demo_web/live/card_live.ex:10 (demo) "],
    location: "12x",
    testId: "malformed-location",
  }));
  cases.push(annotatedPhoenixElement(document, {
    comments: [
      " @caller lib/demo_web/live/card_live.ex:29 (demo) ",
      " @caller lib/demo_web/live/card_live.ex:30 (demo) ",
      " <DemoWeb.CoreComponents.button> lib/demo_web/components/core_components.ex:200 (demo) ",
    ],
    location: "218",
    testId: "duplicate-caller",
  }));
  cases.push(annotatedPhoenixElement(document, {
    comments: [" <Phoenix.Component.render> lib/phoenix/component.ex:10 (phoenix_live_view) "],
    location: "11",
    testId: "dependency-owned",
  }));
  cases.push(annotatedPhoenixElement(document, {
    comments: [" <DemoWeb.CardLive.render> /home/dev/demo/lib/card_live.ex:10 (demo) "],
    location: "11",
    testId: "absolute-path",
  }));
  cases.push(annotatedPhoenixElement(document, {
    comments: [],
    location: "99",
    testId: "patched-stale",
  }));

  let requestBody;
  const sandbox = { TextEncoder, URL, clearTimeout() {}, setTimeout() { return 1; } };
  vm.runInNewContext(fs.readFileSync(path.join(root, assets.phoenix), "utf8"), sandbox);
  const mounted = sandbox.PiBrowserTaskbar.mount({
    autoRefresh: false,
    csrfToken: "token",
    document,
    fetch: async (_url, options) => {
      requestBody = JSON.parse(options.body);
      return {
        ok: true,
        status: 202,
        json: async () => ({ contract_version: 1, session: { id: "session", status: "ready" }, task: null }),
      };
    },
    location: { origin: "http://localhost:4000", pathname: "/cards", search: "" },
    projectApp: "demo",
  });
  const mark = mounted.element.shadowRoot.querySelector("[data-mark]");
  cases.forEach((element) => select(mark, document, element));

  await mounted.submit("Use the available source evidence.");

  const sources = requestBody.context.focus_points.map((point) => point.source);
  assert.deepEqual(sources[0], {
    status: "available",
    references: [{
      role: "template",
      path: "lib/demo_web/controllers/page_html/home.html.heex",
      line: 12,
      precision: "line",
    }],
  });
  assert.deepEqual(sources[1], {
    status: "available",
    references: [
      {
        role: "definition",
        path: "lib/demo_web/components/core_components.ex",
        line: 200,
        symbol: "DemoWeb.CoreComponents.button",
        precision: "line",
      },
      {
        role: "caller",
        path: "lib/demo_web/live/card_live.ex",
        line: 30,
        precision: "line",
      },
    ],
  });
  assert.deepEqual(sources[2], {
    status: "available",
    references: [{
      role: "template",
      path: "lib/demo_web/live/card_live.ex",
      line: 44,
      precision: "line",
    }],
  });
  assert.deepEqual(sources.slice(3).map((source) => source.status), [
    "ambiguous", "ambiguous", "external", "external", "unavailable",
  ]);
  assert.ok(sources.every((source) => source.references.length <= 2));
  assert.deepEqual(requestBody.context.snapshot.children[0].children[0].source, sources[0]);
  assert.doesNotMatch(JSON.stringify(requestBody.context), /@caller|<DemoWeb|\/home\/dev|phoenix_live_view/u);
});

test("Phoenix HEEx hints reject traversal and malformed annotation comments", async () => {
  const document = fakeDocument();
  const elements = [
    annotatedPhoenixElement(document, {
      comments: [" <DemoWeb.CardLive.render> ../outside/card_live.ex:10 (demo) "],
      location: "11",
      testId: "out-of-project",
    }),
    annotatedPhoenixElement(document, {
      comments: [" <DemoWeb.CardLive.render> malformed annotation "],
      location: "12",
      testId: "malformed-comment",
    }),
  ];
  let requestBody;
  const sandbox = { TextEncoder, URL, clearTimeout() {}, setTimeout() { return 1; } };
  vm.runInNewContext(fs.readFileSync(path.join(root, assets.phoenix), "utf8"), sandbox);
  const mounted = sandbox.PiBrowserTaskbar.mount({
    autoRefresh: false,
    csrfToken: "token",
    document,
    fetch: async (_url, options) => {
      requestBody = JSON.parse(options.body);
      return {
        ok: true,
        status: 202,
        json: async () => ({ contract_version: 1, session: { id: "session", status: "ready" }, task: null }),
      };
    },
    location: { origin: "http://localhost:4000", pathname: "/cards", search: "" },
    projectApp: "demo",
  });
  const mark = mounted.element.shadowRoot.querySelector("[data-mark]");
  elements.forEach((element) => select(mark, document, element));

  await mounted.submit("Classify unsafe source evidence.");

  assert.deepEqual(
    requestBody.context.focus_points.map((point) => point.source),
    [
      { status: "external", references: [] },
      { status: "ambiguous", references: [] },
    ],
  );
  assert.doesNotMatch(JSON.stringify(requestBody.context), /outside|malformed annotation/u);
});

function annotatedPhoenixElement(document, { comments, location, testId }) {
  const wrapper = document.createElement("section");
  document.body.appendChild(wrapper);
  comments.forEach((value) => wrapper.appendChild(comment(value)));
  const element = document.createElement("button");
  element.setAttribute("data-testid", testId);
  if (location !== null) element.setAttribute("data-phx-loc", location);
  wrapper.appendChild(element);
  return element;
}

function comment(nodeValue) {
  return { nodeType: 8, nodeValue, previousSibling: null, parentNode: null };
}

test("Browser Client shares focus detail fairly before allocating the whole-page remainder", async () => {
  const document = fakeDocument();
  const focuses = [1, 2].map((number) => {
    const element = document.createElement("section");
    element.setAttribute("data-testid", `focus-${number}`);
    for (let index = 0; index < 99; index += 1) {
      const child = document.createElement("p");
      child.childNodes.push({ nodeType: 3, nodeValue: `${number}-${index}`.padEnd(1000, "x") });
      element.appendChild(child);
    }
    document.body.appendChild(element);
    return element;
  });
  let requestBody;
  const sandbox = { TextEncoder, URL, clearTimeout() {}, setTimeout() { return 1; } };
  vm.runInNewContext(fs.readFileSync(path.join(root, assets.phoenix), "utf8"), sandbox);
  const mounted = sandbox.PiBrowserTaskbar.mount({
    autoRefresh: false,
    csrfToken: "token",
    document,
    fetch: async (_url, options) => {
      requestBody = JSON.parse(options.body);
      return {
        ok: true,
        status: 202,
        json: async () => ({ contract_version: 1, session: { id: "session", status: "ready" }, task: null }),
      };
    },
    location: { origin: "http://localhost:4000", pathname: "/", search: "" },
  });
  const mark = mounted.element.shadowRoot.querySelector("[data-mark]");
  focuses.forEach((element) => select(mark, document, element));

  await mounted.submit("Compare both focused sections.");

  const points = requestBody.context.focus_points;
  assert.equal(points.length, 2);
  assert.ok(points.every((point) => point.subtree.children.length > 0));
  assert.ok(points.every((point) => point.subtree.children.length < 99));
  assert.ok(Math.abs(Buffer.byteLength(JSON.stringify(points[0])) - Buffer.byteLength(JSON.stringify(points[1]))) < 1100);
  assert.ok(Buffer.byteLength(JSON.stringify(points), "utf8") <= 48 * 1024);
  assert.ok(Buffer.byteLength(JSON.stringify(requestBody.context), "utf8") <= 96 * 1024);
  assert.deepEqual(
    requestBody.context.truncation.filter((entry) => entry.section.startsWith("focus:")).map((entry) => entry.reasons),
    [["bytes"], ["bytes"]],
  );
  assert.equal(requestBody.context.snapshot.tag, "body");
});

function select(markButton, document, element) {
  markButton.dispatchEvent({ type: "click" });
  document.dispatch("click", element);
}

for (const framework of Object.keys(assets)) {
  test(`${framework} Browser Client stops a running task and locks active controls`, async () => {
    const document = fakeDocument();
    const requests = [];
    const snapshots = [
      {
        contract_version: 1,
        session: { id: "session", status: "busy", model: "test/fake", error: null },
        task: { id: "task/id", status: "running", output: "", activity: "Pi is working" },
      },
      {
        contract_version: 1,
        session: { id: "session", status: "busy", model: "test/fake", error: null },
        task: { id: "task/id", status: "cancelling", output: "", activity: "Stopping Pi" },
      },
      {
        contract_version: 1,
        session: { id: "session", status: "ready", model: "test/fake", error: null },
        task: { id: "task/id", status: "cancelled", output: "", activity: "Task stopped", finished_at: "2026-01-01T00:00:00Z" },
      },
    ];
    const sandbox = { TextEncoder, URL, clearTimeout() {}, setTimeout() { return 1; } };
    vm.runInNewContext(fs.readFileSync(path.join(root, assets[framework]), "utf8"), sandbox);
    const mounted = sandbox.PiBrowserTaskbar.mount({
      autoRefresh: false,
      csrfToken: "native-csrf-token",
      document,
      fetch: async (url, options) => {
        requests.push({ url, options });
        return { ok: true, status: options.method === "GET" ? 200 : 202, json: async () => snapshots.shift() };
      },
      location: { origin: "http://localhost:4000", pathname: "/", search: "" },
    });

    await mounted.submit("Make a change.");
    const shadow = mounted.element.shadowRoot;
    assert.equal(shadow.querySelector("[data-run]").textContent, "Stop task");
    assert.equal(shadow.querySelector("[data-run]").disabled, false);
    assert.equal(shadow.querySelector("[data-prompt]").disabled, true);
    assert.equal(shadow.querySelector("[data-mark]").disabled, true);
    assert.equal(shadow.querySelector("[data-clear]").disabled, true);
    assert.equal(shadow.querySelector("[data-reset]").disabled, true);
    assert.equal(shadow.querySelector("[data-cancel-warning]").hidden, false);

    shadow.querySelector("[data-run]").dispatchEvent({ type: "click" });
    await new Promise((resolve) => setImmediate(resolve));

    assert.equal(requests[1].url, "/dev/pi-browser-taskbar/tasks/task%2Fid");
    assert.equal(requests[1].options.method, "DELETE");
    assert.equal(requests[1].options.headers["x-csrf-token"], "native-csrf-token");
    assert.equal(shadow.querySelector("[data-run]").textContent, "Stopping…");
    assert.equal(shadow.querySelector("[data-run]").disabled, true);
    assert.equal(shadow.querySelector("[data-activity]").textContent, "Stopping Pi");

    await mounted.refresh();
    assert.equal(shadow.querySelector("[data-status]").textContent, "Stopped");
    assert.equal(shadow.querySelector("[data-activity]").textContent, "Task stopped");
    assert.equal(shadow.querySelector("[data-cancel-warning]").hidden, false);
  });
}

for (const framework of Object.keys(assets)) {
  test(`${framework} Browser Client confirms reset inline and preserves draft and marks`, async () => {
    const document = fakeDocument();
    const focus = document.createElement("button");
    focus.setAttribute("data-testid", "preserved-focus");
    document.body.appendChild(focus);
    const requests = [];
    let resolveReset;
    const resetResponse = new Promise((resolve) => { resolveReset = resolve; });
    const ready = {
      contract_version: 1,
      session: { id: "old-session", status: "ready", model: "test/fake", error: null },
      task: { id: "old-task", status: "completed", output: "Old feedback", activity: "Task completed" },
    };
    const sandbox = { TextEncoder, URL, clearTimeout() {}, setTimeout() { return 1; } };
    vm.runInNewContext(fs.readFileSync(path.join(root, assets[framework]), "utf8"), sandbox);
    const mounted = sandbox.PiBrowserTaskbar.mount({
      autoRefresh: false,
      csrfToken: "native-csrf-token",
      document,
      fetch: async (url, options) => {
        requests.push({ url, options });
        if (options.method === "GET") return { ok: true, status: 200, json: async () => ready };
        return resetResponse;
      },
      location: { origin: "http://localhost:4000", pathname: "/", search: "" },
    });

    await mounted.refresh();
    const shadow = mounted.element.shadowRoot;
    shadow.querySelector("[data-prompt]").value = "Keep this draft.";
    select(shadow.querySelector("[data-mark]"), document, focus);

    const reset = shadow.querySelector("[data-reset]");
    assert.equal(reset.disabled, false);
    reset.dispatchEvent({ type: "click" });
    assert.equal(reset.textContent, "Start fresh?");
    assert.equal(requests.length, 1);

    reset.dispatchEvent({ type: "click" });
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(requests[1].url, "/dev/pi-browser-taskbar/session/reset");
    assert.equal(requests[1].options.method, "POST");
    assert.equal(requests[1].options.headers["x-csrf-token"], "native-csrf-token");
    assert.equal(shadow.querySelector("[data-activity]").textContent, "Starting a fresh session");
    assert.equal(shadow.querySelector("[data-prompt]").disabled, true);
    assert.equal(reset.disabled, true);

    resolveReset({
      ok: true,
      status: 202,
      json: async () => ({
        contract_version: 1,
        session: { id: "new-session", status: "ready", model: "test/fake", error: null },
        task: null,
      }),
    });
    await new Promise((resolve) => setImmediate(resolve));

    assert.equal(shadow.querySelector("[data-prompt]").value, "Keep this draft.");
    assert.match(shadow.querySelector("[data-scope]").textContent, /^1 marked element/u);
    assert.equal(shadow.querySelector("[data-output]").hidden, true);
    assert.equal(reset.textContent, "New session");
    assert.equal(reset.disabled, false);
  });
}

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
      this.style = {};
    }

    addEventListener(name, listener) { (this.listeners[name] ||= []).push(listener); }
    appendChild(child) {
      child.previousSibling = this.childNodes.at(-1) || null;
      child.parentNode = this;
      this.childNodes.push(child);
      if (child.nodeType === 1) {
        this.children.push(child);
        child.parentElement = this;
      }
      return child;
    }
    attachShadow() { this.shadowRoot = new FakeShadowRoot(); return this.shadowRoot; }
    contains(candidate) {
      return candidate === this || this.children.some((child) => child.contains?.(candidate));
    }
    dispatchEvent(event) {
      event.target ||= this;
      for (const listener of this.listeners[event.type] || []) listener(event);
    }
    focus() { this.focused = true; }
    getAttribute(name) { return this.attributes.get(name) ?? null; }
    getBoundingClientRect() { return this.rectangle || { left: 10, top: 20, width: 100, height: 30 }; }
    hasAttribute(name) { return this.attributes.has(name); }
    removeAttribute(name) { this.attributes.delete(name); }
    replaceChildren(...children) {
      this.childNodes = [];
      this.children = [];
      children.forEach((child) => this.appendChild(child));
    }
    setAttribute(name, value) {
      this.attributes.set(name, String(value));
      if (name === "class") this.classList = String(value).split(/\s+/u).filter(Boolean);
      else this[name] = String(value);
    }
    toggleAttribute(name, force) {
      if (force) this.setAttribute(name, ""); else this.removeAttribute(name);
      return force;
    }
  }

  class FakeShadowRoot {
    constructor() {
      this.elements = new Map();
      for (const selector of [
        "[data-panel]", "[data-toggle]", "[data-status]", "[data-scope]", "[data-prompt]",
        "[data-run]", "[data-output]", "[data-activity]", "[data-error]", "[data-mark]",
        "[data-clear]", "[data-marks]", "[data-hover-outline]", "[data-overlays]",
        "[data-cancel-warning]", "[data-reset]",
      ]) {
        this.elements.set(selector, new FakeElement());
      }
    }
    querySelector(selector) { return this.elements.get(selector); }
    set innerHTML(value) { this.markup = value; }
  }

  const body = new FakeElement("body");
  const listeners = {};
  const allElements = () => {
    const result = [];
    const queue = [body];
    while (queue.length > 0) {
      const element = queue.shift();
      result.push(element);
      queue.push(...element.children);
    }
    return result;
  };
  const matches = (element, segment) => {
    const attribute = segment.match(/^\[([a-z-]+)="(.*)"\]$/u);
    if (attribute) return element.getAttribute(attribute[1]) === attribute[2].replace(/\\"/gu, '"').replace(/\\\\/gu, "\\");
    const parsed = segment.match(/^([a-z][a-z0-9-]*)(?::nth-of-type\(([0-9]+)\))?$/u);
    if (!parsed || element.localName !== parsed[1]) return false;
    if (!parsed[2]) return true;
    const siblings = element.parentElement.children.filter((candidate) => candidate.localName === element.localName);
    return siblings.indexOf(element) + 1 === Number(parsed[2]);
  };
  const document = {
    body,
    defaultView: {
      addEventListener() {},
      getComputedStyle(element) {
        return element.computedStyle || { display: "block", visibility: "visible", contentVisibility: "visible" };
      },
    },
    addEventListener(name, listener) { (listeners[name] ||= []).push(listener); },
    dispatch(name, target, extra = {}) {
      const event = {
        type: name,
        target,
        preventDefault() { this.defaultPrevented = true; },
        stopImmediatePropagation() { this.propagationStopped = true; },
        ...extra,
      };
      for (const listener of listeners[name] || []) listener(event);
      return event;
    },
    createElement(localName) { return new FakeElement(localName); },
    getElementById(id) { return allElements().find((element) => element.getAttribute?.("id") === id) || null; },
    querySelector() { return null; },
    querySelectorAll(selector) {
      const segments = selector.split(" > ");
      return allElements().filter((element) => {
        let current = element;
        for (let index = segments.length - 1; index >= 0; index -= 1) {
          if (!current || !matches(current, segments[index])) return false;
          current = current.parentElement;
        }
        return true;
      });
    },
  };
  return document;
}
