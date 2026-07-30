({
  framework: "rails",
  sourceHint(element) {
    let branch = element;

    while (branch?.parentNode) {
      const range = enclosingRange(branch.parentNode, branch);
      if (range.status) return hint(range.status);
      if (range.path) {
        const path = projectPath(range.path);
        return path
          ? hint("available", [Object.freeze({ role: "template", path, precision: "template" })])
          : hint("external");
      }
      branch = branch.parentNode;
    }

    return hint("unavailable");
  },
})

function enclosingRange(parent, branch) {
  const children = Array.from(parent?.childNodes || []);
  const branchIndex = children.indexOf(branch);
  if (branchIndex < 0) return {};

  const stack = [];
  const ranges = [];
  const invalidBegins = [];
  const invalidEnds = [];

  children.forEach((node, index) => {
    if (node.nodeType !== 8) return;
    const annotation = parseAnnotation(node.nodeValue);
    if (!annotation) return;
    if (annotation.kind === "malformed") {
      (annotation.direction === "begin" ? invalidBegins : invalidEnds).push(index);
      return;
    }
    if (annotation.kind === "begin") {
      stack.push({ index, path: annotation.path });
      return;
    }

    const opening = stack.at(-1);
    if (opening?.path === annotation.path) {
      stack.pop();
      ranges.push({ start: opening.index, end: index, path: opening.path });
      return;
    }

    invalidEnds.push(index);
    invalidBegins.push(...stack.map(({ index: start }) => start));
    stack.length = 0;
  });

  invalidBegins.push(...stack.map(({ index }) => index));
  const candidates = ranges
    .filter(({ start, end }) => start < branchIndex && branchIndex < end)
    .sort((left, right) => right.start - left.start || left.end - right.end);
  const innermost = candidates[0];
  const suspicious = (start, end) =>
    invalidBegins.some((index) => start < index && index < branchIndex) ||
    invalidEnds.some((index) => branchIndex < index && index < end);

  if (innermost) {
    return suspicious(innermost.start, innermost.end) ? { status: "ambiguous" } : innermost;
  }
  return suspicious(-1, children.length) ? { status: "ambiguous" } : {};
}

function parseAnnotation(value) {
  if (typeof value !== "string") return null;
  const match = value.match(/^\s*(BEGIN|END)\s+([^\r\n]*?\S)\s*$/u);
  if (match && match[2].endsWith(".erb")) {
    return { kind: match[1].toLowerCase(), path: match[2] };
  }
  const marker = value.match(/^\s*(BEGIN|END)\b/u);
  return marker && /(?:\.erb\b|app[\\/]views)/u.test(value)
    ? { kind: "malformed", direction: marker[1].toLowerCase() }
    : null;
}

function projectPath(path) {
  if (!path || path.startsWith("/") || path.includes("\\") || /^[A-Za-z]:/u.test(path)) return null;
  const segments = path.split("/");
  if (segments.some((segment) => !segment || segment === "." || segment === "..")) return null;
  if (segments[0] === ".bundle" || (segments[0] === "vendor" && segments[1] === "bundle")) return null;
  return new TextEncoder().encode(path).byteLength <= 500 ? path : null;
}

function hint(status, references = []) {
  return Object.freeze({ references: Object.freeze(references), status });
}
