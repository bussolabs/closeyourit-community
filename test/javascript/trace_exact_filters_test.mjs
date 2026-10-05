import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import test from "node:test"
import vm from "node:vm"

async function setup({ hidden = true, exact = true, value = "" } = {}) {
  const context = vm.createContext({ document: { addEventListener() {}, removeEventListener() {} }, setTimeout })
  const module = new vm.SourceTextModule(await readFile(new URL("../../app/javascript/controllers/ui/filter_bar_controller.js", import.meta.url), "utf8"), { context })
  await module.link(name => new vm.SyntheticModule([name === "lib/icon" ? "icon" : "Controller"], function () {
    this.setExport(name === "lib/icon" ? "icon" : "Controller", name === "lib/icon" ? () => {} : class {})
  }, { context }))
  await module.evaluate()
  const field = { value, disabled: false }
  const chip = { hidden, dataset: { filterKey: "environment" },
    querySelector: selector => selector === "[data-filter-bar-value]" ? field : null,
    querySelectorAll: () => exact ? [field] : [] }
  const controller = new module.namespace.default()
  let submits = 0
  Object.assign(controller, { chipTargets: [chip], formTarget: { querySelector: () => null, requestSubmit: () => { submits++ } },
    closeMenu() {} })
  return { controller, chip, field, event: { currentTarget: { dataset: { filterKey: "environment" }, closest: () => chip } }, submits: () => submits }
}

test("hidden exact filters are excluded while opening permits an explicitly empty value", async () => {
  const h = await setup()
  h.controller.connect()
  assert.equal(h.field.disabled, true)
  h.controller.chooseFilter(h.event)
  assert.equal(h.field.disabled, false)
  h.controller.submit()
  assert.equal(h.submits(), 1)
  assert.equal(h.field.value, "")
})

test("removing an active empty exact filter submits and excludes the removed parameter", async () => {
  const h = await setup({ hidden: false })
  h.controller.connect()
  assert.equal(h.field.disabled, false)
  h.controller.remove(h.event)
  assert.equal(h.field.disabled, true)
  assert.equal(h.chip.hidden, true)
  assert.equal(h.submits(), 1)
})

test("saved whitespace exact values rehydrate while unmarked legacy filters remain unchanged", async () => {
  const saved = await setup({ hidden: false, value: " " })
  saved.controller.connect()
  assert.equal(saved.field.disabled, false)
  assert.equal(saved.field.value, " ")
  const legacy = await setup({ exact: false })
  legacy.controller.connect()
  assert.equal(legacy.field.disabled, false)
})
