function createBrowserClient({ framework, contextProvider, productVersion, contractVersion }) {
  if (!framework || !contextProvider || typeof contextProvider.sourceHint !== "function") {
    throw new TypeError("A framework and ContextProvider are required");
  }

  function mount(bootstrap = {}) {
    const mountBase = bootstrap.mountBase || "/dev/pi-browser-taskbar";
    const metadata = { contractVersion, framework, mountBase, productVersion };
    const document = bootstrap.document || globalThis.document;

    if (!document?.body) return Object.freeze(metadata);

    const existing = document.querySelector?.("[data-pi-browser-taskbar-host]");
    if (existing?.piBrowserTaskbar) return existing.piBrowserTaskbar;

    const host = document.createElement("div");
    host.setAttribute("data-pi-browser-taskbar-host", "");
    const shadow = host.attachShadow({ mode: "open" });
    shadow.innerHTML = markup();
    document.body.appendChild(host);

    const controls = {
      activity: shadow.querySelector("[data-activity]"),
      error: shadow.querySelector("[data-error]"),
      output: shadow.querySelector("[data-output]"),
      panel: shadow.querySelector("[data-panel]"),
      prompt: shadow.querySelector("[data-prompt]"),
      run: shadow.querySelector("[data-run]"),
      scope: shadow.querySelector("[data-scope]"),
      status: shadow.querySelector("[data-status]"),
      toggle: shadow.querySelector("[data-toggle]"),
    };
    const fetchRequest = bootstrap.fetch || globalThis.fetch?.bind(globalThis);
    const pageLocation = bootstrap.location || globalThis.location;
    let snapshot = null;
    let pollTimer = null;
    let snapshotGeneration = 0;

    controls.toggle.addEventListener("click", () => {
      controls.panel.hidden = !controls.panel.hidden;
      controls.toggle.setAttribute("aria-expanded", String(!controls.panel.hidden));
      if (!controls.panel.hidden) controls.prompt.focus?.();
    });
    controls.run.addEventListener("click", () => submit(controls.prompt.value).catch(showError));
    controls.prompt.addEventListener("input", renderControls);

    async function submit(prompt) {
      const normalizedPrompt = String(prompt || "").trim();
      if (!normalizedPrompt) throw new TypeError("A prompt is required");

      const context = wholePageContext(document, pageLocation, host);
      const generation = ++snapshotGeneration;

      try {
        const nextSnapshot = await request("/tasks", {
          method: "POST",
          body: { prompt: normalizedPrompt, context },
        });
        if (generation !== snapshotGeneration) return snapshot;
        snapshot = nextSnapshot;
        render();
        schedulePoll(500);
        return snapshot;
      } catch (error) {
        if (generation === snapshotGeneration) throw error;
        return snapshot;
      }
    }

    async function refresh() {
      const generation = ++snapshotGeneration;

      try {
        const nextSnapshot = await request("/state", { method: "GET" });
        if (generation !== snapshotGeneration) return snapshot;
        snapshot = nextSnapshot;
        render();
        schedulePoll(active(snapshot) ? 500 : 30000);
        return snapshot;
      } catch (error) {
        if (generation === snapshotGeneration) throw error;
        return snapshot;
      }
    }

    async function request(path, { method, body } = {}) {
      if (typeof fetchRequest !== "function") throw new Error("Browser fetch is unavailable");
      const headers = { accept: "application/json" };
      const options = { method: method || "GET", headers };

      if (body) {
        headers["content-type"] = "application/json";
        options.body = JSON.stringify(body);
      }
      if (options.method !== "GET") {
        headers["x-csrf-token"] = bootstrap.csrfToken || "";
      }

      const response = await fetchRequest(`${mountBase}${path}`, options);
      const payload = await response.json().catch(() => ({}));
      if (!response.ok) {
        const error = new Error(payload.error?.message || `Pi task request failed (${response.status})`);
        error.code = payload.error?.code;
        error.status = response.status;
        throw error;
      }
      return payload;
    }

    function render() {
      const session = snapshot?.session || { status: "starting" };
      const task = snapshot?.task;
      controls.status.textContent = visibleStatus(session, task);
      controls.status.setAttribute("data-state", task?.status || session.status);
      controls.scope.textContent = "Whole page · bounded structural context";
      controls.activity.textContent = task?.activity || connectingActivity(session);
      controls.activity.hidden = !controls.activity.textContent;
      controls.output.textContent = task?.output || "";
      controls.output.hidden = !controls.output.textContent;
      controls.error.textContent = task?.error || session.error || "";
      controls.error.hidden = !controls.error.textContent;
      renderControls();
    }

    function renderControls() {
      const busy = active(snapshot);
      controls.prompt.disabled = busy;
      controls.run.disabled = busy || !String(controls.prompt.value || "").trim();
      controls.run.textContent = busy ? "Working…" : "Run with Pi";
    }

    function schedulePoll(delay) {
      globalThis.clearTimeout?.(pollTimer);
      pollTimer = globalThis.setTimeout?.(() => refresh().catch(showError), delay);
    }

    function showError(error) {
      controls.error.textContent = error?.message || "Pi Browser Taskbar is unavailable";
      controls.error.hidden = false;
    }

    const mounted = Object.freeze({ ...metadata, element: host, refresh, submit });
    host.piBrowserTaskbar = mounted;
    render();
    if (bootstrap.autoRefresh !== false) refresh().catch(showError);
    return mounted;
  }

  return Object.freeze({ mount });
}

function wholePageContext(document, location, taskbarHost) {
  const queryNames = [];
  for (const name of queryParameterNames(location)) {
    const boundedName = normalizedText(name, 128);
    if (boundedName && !queryNames.includes(boundedName) && queryNames.length < 32) queryNames.push(boundedName);
  }

  const state = { nodes: 0, reasons: [] };
  const snapshot = captureNode(document.body, taskbarHost, state, 0, document) || { tag: "body", children: [] };
  enforceSnapshotBytes(snapshot, state, 48 * 1024);

  return {
    contract_version: 1,
    location: {
      origin: location?.origin || "http://localhost",
      path: normalizedText(location?.pathname || "/", 2048) || "/",
      query_names: queryNames,
    },
    route: null,
    snapshot,
    focus_points: [],
    truncation: state.reasons.length > 0 ? [{ section: "page", reasons: Array.from(new Set(state.reasons)) }] : [],
  };
}

function captureNode(element, taskbarHost, state, depth, document) {
  if (!element?.localName || element === taskbarHost || excluded(element, document)) return null;
  if (state.nodes >= 750) {
    state.reasons.push("nodes");
    return null;
  }
  if (depth > 12) {
    state.reasons.push("depth");
    return null;
  }
  state.nodes += 1;

  const node = { tag: String(element.localName).toLowerCase(), children: [] };
  const name = normalizedText(element.getAttribute?.("aria-label"), 512, state);
  const identifier = normalizedText(element.getAttribute?.("id"), 256, state);
  const directText = normalizedText(
    Array.from(element.childNodes || [])
      .filter((child) => child.nodeType === 3)
      .map((child) => child.nodeValue || "")
      .join(" "),
    1000,
    state,
  );
  const classes = Array.from(element.classList || []).slice(0, 32).map((value) => normalizedText(value, 128, state)).filter(Boolean);

  if (name) node.name = name;
  if (directText) node.text = directText;
  if (identifier) node.id = identifier;
  if (classes.length > 0) node.classes = Array.from(new Set(classes));

  for (const child of Array.from(element.children || [])) {
    const captured = captureNode(child, taskbarHost, state, depth + 1, document);
    if (captured) node.children.push(captured);
  }
  return node;
}

function excluded(element, document) {
  const tag = String(element.localName).toLowerCase();
  if (["script", "style", "template", "meta", "link", "head", "iframe", "input", "textarea", "select"].includes(tag)) return true;
  if (element.hidden || element.hasAttribute?.("hidden") || element.hasAttribute?.("inert")) return true;
  if (element.isContentEditable || element.getAttribute?.("contenteditable") === "true") return true;
  if (element.getAttribute?.("aria-hidden") === "true") return true;

  const style = document?.defaultView?.getComputedStyle?.(element);
  return style?.display === "none" || style?.visibility === "hidden" || style?.contentVisibility === "hidden" || Number(style?.opacity) === 0;
}

function queryParameterNames(location) {
  if (location?.searchParams?.keys) return Array.from(location.searchParams.keys());

  return String(location?.search || "")
    .replace(/^\?/, "")
    .split("&")
    .filter(Boolean)
    .map((pair) => {
      const encodedName = pair.split("=", 1)[0].replace(/\+/g, " ");
      try {
        return decodeURIComponent(encodedName);
      } catch (_error) {
        return encodedName;
      }
    });
}

function normalizedText(value, maximumBytes, state) {
  const normalized = String(value || "").normalize("NFC").replace(/[\u0000-\u001f\u007f\u202a-\u202e\u2066-\u2069]/gu, " ").replace(/\s+/gu, " ").trim();
  let bounded = "";
  let bytes = 0;
  const encoder = new TextEncoder();

  for (const character of normalized) {
    const characterBytes = encoder.encode(character).byteLength;
    if (bytes + characterBytes > maximumBytes) {
      state?.reasons?.push("string");
      break;
    }
    bounded += character;
    bytes += characterBytes;
  }
  return bounded;
}

function enforceSnapshotBytes(snapshot, state, maximumBytes) {
  while (utf8Size(JSON.stringify(snapshot)) > maximumBytes) {
    const removable = [];
    collectRemovableNodes(snapshot, removable);
    const candidate = removable.at(-1);
    if (!candidate) break;
    candidate.parent.children.splice(candidate.index, 1);
    state.reasons.push("bytes");
  }
}

function collectRemovableNodes(node, removable) {
  for (const [index, child] of node.children.entries()) {
    removable.push({ parent: node, index });
    collectRemovableNodes(child, removable);
  }
}

function utf8Size(value) {
  return new TextEncoder().encode(value).byteLength;
}

function active(snapshot) {
  return snapshot?.session?.status === "busy" || ["running", "cancelling"].includes(snapshot?.task?.status);
}

function visibleStatus(session, task) {
  if (task?.status === "running" || task?.status === "cancelling") return "Working";
  if (task?.status === "completed" || task?.status === "failed") return "Finished";
  if (task?.status === "cancelled") return "Stopped";
  if (session.status === "ready") return "Ready";
  if (session.status === "unavailable") return "Unavailable";
  return "Connecting";
}

function connectingActivity(session) {
  if (session.status === "starting") return "Connecting to the local Pi session";
  if (session.status === "unavailable") return "Check that Pi is installed and authenticated";
  return "";
}

function markup() {
  return `
    <style>${taskbarStyles}</style>
    <section data-panel hidden aria-label="Pi browser task">
      <header><strong>PI / PAGE TASK</strong><span data-status aria-live="polite">Connecting</span></header>
      <p data-scope>Whole page · bounded structural context</p>
      <label>What should change?<textarea data-prompt maxlength="4000" rows="3"></textarea></label>
      <p data-activity aria-live="polite"></p>
      <pre data-output hidden></pre>
      <p data-error hidden role="alert"></p>
      <button data-run type="button" disabled>Run with Pi</button>
    </section>
    <button data-toggle type="button" aria-expanded="false" aria-label="Open Pi browser taskbar">π <span>Page task</span></button>
  `;
}
