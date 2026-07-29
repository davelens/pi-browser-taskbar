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
