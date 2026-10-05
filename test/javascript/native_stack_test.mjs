import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import test from "node:test"
import vm from "node:vm"

class Select { constructor(value) { this.value = value } }

async function setup() {
  const context = vm.createContext({ HTMLSelectElement: Select })
  const module = new vm.SourceTextModule(await readFile(new URL("../../app/javascript/controllers/native_stack_controller.js", import.meta.url), "utf8"), { context })
  await module.link(() => new vm.SyntheticModule(["Controller"], function () { this.setExport("Controller", class {}) }, { context }))
  await module.evaluate()
  const controller = new module.namespace.default()
  controller.threadTargets = [0, 1, 0, 1].map(index => ({ dataset: { nativeThread: String(index) }, hidden: false }))
  controller.selectedValue = 1
  return controller
}

test("selects the actual crash thread in both received and derived views and isolates occurrences", async () => {
  const first = await setup(), other = await setup()
  first.connect()
  other.connect()
  assert.deepEqual(first.threadTargets.map(panel => panel.hidden), [true, false, true, false])
  first.select({ target: new Select("0") })
  assert.deepEqual(first.threadTargets.map(panel => panel.hidden), [false, true, false, true])
  assert.deepEqual(other.threadTargets.map(panel => panel.hidden), [true, false, true, false])
})

test("ignores unrelated controls and unknown thread indices", async () => {
  const controller = await setup()
  controller.connect()
  controller.select({ target: { value: "0" } })
  controller.select({ target: new Select("99") })
  assert.equal(controller.selectedValue, 1)
})
