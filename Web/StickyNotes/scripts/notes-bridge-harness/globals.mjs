// Minimal globals so the real Sticky Notes bridge modules run under Node with no browser. Capture outbound
// messages so the harness can assert the JS -> Swift half of each external-control round-trip. Imported FIRST
// by run.mjs so it is evaluated before the bridge modules.
const messages = [];

globalThis.window = globalThis.window || {};
globalThis.window.webkit = {
  messageHandlers: {
    notes: {
      postMessage(message) {
        messages.push(message);
      },
    },
  },
};

export function clearPostedMessages() {
  messages.length = 0;
}

export function postedMessages() {
  return messages.slice();
}
