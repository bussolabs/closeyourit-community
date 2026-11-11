import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import test from "node:test"
const source = await readFile(new URL("../../app/javascript/coworker_office/daylight.js", import.meta.url))
const { daylightAt } = await import(`data:text/javascript;base64,${source.toString("base64")}`)
const at = (hour, minute = 0, second = 0) => daylightAt(new Date(2026, 10, 10, hour, minute, second))

test("local clock selects night, dawn, day and dusk", () => {
  assert.deepEqual(at(0), { daylight: 0, warmth: 0 })
  assert.deepEqual(at(6, 30), { daylight: 0.35, warmth: 1 })
  assert.deepEqual(at(12), { daylight: 1, warmth: 0 })
  assert.deepEqual(at(18, 30), { daylight: 0.35, warmth: 1 })
  assert.deepEqual(at(23), at(0))
})
test("light remains bounded and continuous across every transition and midnight", () => {
  let previous = at(0)
  for (let second = 1; second <= 86400; second++) {
    const current = at(0, 0, second)
    for (const key of ["daylight", "warmth"]) {
      assert.ok(current[key] >= 0 && current[key] <= 1)
      assert.ok(Math.abs(current[key] - previous[key]) < 0.001)
    }
    previous = current
  }
})
