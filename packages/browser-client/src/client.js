function createBrowserClient({ framework, contextProvider, productVersion, contractVersion }) {
  if (!framework || !contextProvider || typeof contextProvider.sourceHint !== "function") {
    throw new TypeError("A framework and ContextProvider are required");
  }

  function mount(bootstrap = {}) {
    const mountBase = bootstrap.mountBase || "/dev/pi-browser-taskbar";

    return Object.freeze({
      contractVersion,
      framework,
      mountBase,
      productVersion,
      sourceHint: (element) => contextProvider.sourceHint(element),
    });
  }

  return Object.freeze({ mount });
}
