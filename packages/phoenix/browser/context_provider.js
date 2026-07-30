({
  framework: "phoenix",
  sourceHint(element, { projectApp } = {}) {
    const location = lineNumber(element?.getAttribute?.("data-phx-loc"));
    if (element?.hasAttribute?.("data-phx-loc") && !location) return hint("ambiguous");
    if (!/^[a-z][a-z0-9_]*$/u.test(projectApp || "")) return hint("unavailable");

    const annotations = precedingAnnotations(element);
    if (annotations.status) return hint(annotations.status);

    const definition = annotations.definition;
    if (!definition) return hint("unavailable");

    const definitionPath = projectPath(definition, projectApp);
    if (!definitionPath) return hint("external");

    if (annotations.caller) {
      const callerPath = projectPath(annotations.caller, projectApp);
      if (!callerPath) return hint("external");
      return hint("available", [
        reference("definition", definitionPath, definition.line, definition.component),
        reference("caller", callerPath, annotations.caller.line),
      ]);
    }

    if (!location) return hint("unavailable");
    if (!definition.component.endsWith(".render") && !definitionPath.endsWith(".heex")) {
      return hint("ambiguous");
    }
    return hint("available", [reference("template", definitionPath, location)]);
  },
})

function precedingAnnotations(element) {
  const annotations = [];
  let node = element;

  while (node) {
    let sibling = node.previousSibling;
    while (sibling) {
      if (sibling.nodeType === 8) {
        const annotation = parseAnnotation(sibling.nodeValue);
        if (annotation) annotations.push(annotation);
      }
      sibling = sibling.previousSibling;
    }
    node = node.parentNode;
  }

  const closed = [];
  for (let index = 0; index < annotations.length; index += 1) {
    const annotation = annotations[index];
    if (annotation.kind === "malformed") return { status: "ambiguous" };
    if (annotation.kind === "closing") {
      closed.push(annotation.component);
      continue;
    }
    if (annotation.kind === "definition" && closed.length > 0) {
      if (closed.pop() !== annotation.component) return { status: "ambiguous" };
      if (annotations[index + 1]?.kind === "caller") index += 1;
      continue;
    }
    if (annotation.kind === "caller") return { status: "ambiguous" };
    if (annotation.kind === "definition") {
      const caller = annotations[index + 1]?.kind === "caller" ? annotations[index + 1] : null;
      if (caller && annotations[index + 2]?.kind === "caller") return { status: "ambiguous" };
      if (!caller && annotations[index + 1]?.kind === "definition") return { status: "ambiguous" };
      return { definition: annotation, caller };
    }
  }

  return closed.length > 0 ? { status: "ambiguous" } : {};
}

function parseAnnotation(value) {
  if (typeof value !== "string") return null;
  const caller = value.match(/^\s*@caller\s+([^\r\n]+):(\d+)\s+\(([a-z][a-z0-9_]*)\)\s*$/u);
  if (caller) {
    const line = lineNumber(caller[2]);
    return line ? { kind: "caller", file: caller[1], line, app: caller[3] } : { kind: "malformed" };
  }

  const definition = value.match(/^\s*<([A-Z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+|:[a-z][a-z0-9_]*)>\s+([^\r\n]+):(\d+)\s+\(([a-z][a-z0-9_]*)\)\s*$/u);
  if (definition) {
    const line = lineNumber(definition[3]);
    if (!line || new TextEncoder().encode(definition[1]).byteLength > 256) return { kind: "malformed" };
    return {
      kind: "definition",
      component: definition[1],
      file: definition[2],
      line,
      app: definition[4],
    };
  }

  const closing = value.match(/^\s*<\/([A-Z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+|:[a-z][a-z0-9_]*)>\s*$/u);
  if (closing) return { kind: "closing", component: closing[1] };
  return /^\s*(?:@caller\b|<\/?(?:[A-Z]|:))/u.test(value) ? { kind: "malformed" } : null;
}

function projectPath(annotation, projectApp) {
  const path = annotation.app === projectApp ? annotation.file : "";
  if (!path || path.startsWith("/") || path.includes("\\") || /^[A-Za-z]:/u.test(path)) return null;
  const segments = path.split("/");
  if (segments.some((segment) => !segment || segment === "." || segment === "..")) return null;
  if (["deps", "_build"].includes(segments[0])) return null;
  return new TextEncoder().encode(path).byteLength <= 500 ? path : null;
}

function lineNumber(value) {
  if (!/^[1-9]\d*$/u.test(String(value || ""))) return null;
  const line = Number(value);
  return Number.isSafeInteger(line) ? line : null;
}

function hint(status, references = []) {
  return Object.freeze({ references: Object.freeze(references), status });
}

function reference(role, path, line, symbol) {
  return Object.freeze({ role, path, line, ...(symbol ? { symbol } : {}), precision: "line" });
}
