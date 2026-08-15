// Registers a module-resolution hook so `node --import ./.../register.mjs run.mjs` runs the real Sticky Notes
// bridge with the DOM-bound source modules redirected to headless stand-ins:
//   src/editor.js    -> editor-model.mjs (a faithful, DOM-free {doc, selection} model)
//   src/render.js    -> view-stubs.mjs   (no-op)
//   src/drag-rail.js -> view-stubs.mjs   (no-op)
// Everything else (actions.js, dictation-target.js, state.js, persistence.js, bridge.js) resolves normally, so
// the harness exercises the shipping store + control flow. See run.mjs.
import module from "node:module";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const editorStub = pathToFileURL(path.join(here, "editor-model.mjs")).href;
const viewStub = pathToFileURL(path.join(here, "view-stubs.mjs")).href;

const REDIRECTS = [
  { suffix: "/src/editor.js", url: editorStub },
  { suffix: "/src/render.js", url: viewStub },
  { suffix: "/src/drag-rail.js", url: viewStub },
];

module.registerHooks({
  resolve(specifier, context, nextResolve) {
    const resolved = nextResolve(specifier, context);
    for (const { suffix, url } of REDIRECTS) {
      if (resolved.url.endsWith(suffix)) return { url, shortCircuit: true };
    }
    return resolved;
  },
});
