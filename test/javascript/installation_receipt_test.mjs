// Run: node --experimental-vm-modules --test test/javascript/installation_receipt_test.mjs
import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import test from "node:test"
import vm from "node:vm"

async function setup() {
  const pending = []
  const context = vm.createContext({ URL, URLSearchParams, AbortController, setTimeout, clearTimeout,
    FormData: class { *[Symbol.iterator]() { yield ["event_id", "new-id"] } },
    fetch: (_url, options) => new Promise((resolve, reject) => pending.push({ resolve, reject, options }))
  })
  const module = new vm.SourceTextModule(await readFile(new URL("../../app/javascript/controllers/installation_receipt_controller.js", import.meta.url), "utf8"), { context })
  await module.link(() => new vm.SyntheticModule(["Controller"], function () { this.setExport("Controller", class {}) }, { context }))
  await module.evaluate()
  const controller = new module.namespace.default()
  Object.assign(controller, { formTarget: { action: "https://example.invalid/receipt", reportValidity: () => true },
    buttonTarget: { disabled: false }, resultTarget: { textContent: "unchecked" }, uncheckedValue: "unchecked",
    pendingValue: "pending", loadingValue: "loading", errorValue: "unavailable", receivedValue: "received" })
  return { controller, pending, check: () => controller.check({ preventDefault() {} }) }
}
const response = state => ({ ok: true, headers: { get: () => "application/json" }, text: async () => JSON.stringify({ data: { state, received_at: "2026-10-04T10:00:00Z", environment: "test", release: "build" } }) })

for (const completion of ["response", "abort"]) {
  test(`editing fields invalidates a previous ${completion} without presenting a check`, async () => {
    const h = await setup()
    const check = h.check()
    h.controller.reset()
    assert.equal(h.pending[0].options.signal.aborted, true)
    if (completion === "response") h.pending[0].resolve(response("received"))
    else h.pending[0].reject(new Error("Aborted"))
    await check
    assert.equal(h.controller.resultTarget.textContent, "unchecked")
    assert.equal(h.controller.buttonTarget.disabled, false)
  })
}

test("a superseded response cannot override the latest check or disconnect", async () => {
  const h = await setup()
  const first = h.check()
  const second = h.check()
  h.pending[1].resolve(response("pending"))
  await second
  h.pending[0].resolve(response("received"))
  await first
  assert.equal(h.controller.resultTarget.textContent, "pending")
  const third = h.check()
  h.controller.disconnect()
  h.pending[2].resolve(response("received"))
  await third
  assert.equal(h.controller.resultTarget.textContent, "loading")
})
