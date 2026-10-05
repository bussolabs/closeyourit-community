// Run: node --experimental-vm-modules --test test/javascript/realtime_lifecycle_test.mjs
import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import test from "node:test"
import vm from "node:vm"

async function setup(name) {
  const pending = []
  const subscriptions = []
  const timers = new Map()
  let nextTimer = 0
  const cable = {
    getConsumer: () => new Promise(resolve => pending.push(resolve))
  }
  const consumer = { subscriptions: { create(identifier, callbacks) {
    const subscription = { identifier, callbacks, beats: [], unsubscriptions: 0,
      perform(action) { this.beats.push(action) },
      unsubscribe() { this.unsubscriptions++ }
    }
    subscriptions.push(subscription)
    return subscription
  } } }
  const context = vm.createContext({ console, window: {},
    setInterval: callback => { timers.set(++nextTimer, callback); return nextTimer },
    clearInterval: id => timers.delete(id)
  })
  const source = await readFile(new URL(`../../app/javascript/controllers/${name}_controller.js`, import.meta.url), "utf8")
  const module = new vm.SourceTextModule(source, { context })
  await module.link(async specifier => {
    const exports = specifier === "@hotwired/stimulus"
      ? { Controller: class {} } : { cable, Turbo: { renderStreamMessage() {} } }
    return new vm.SyntheticModule(Object.keys(exports), function () {
      for (const [key, value] of Object.entries(exports)) this.setExport(key, value)
    }, { context })
  })
  await module.evaluate()
  const controller = new module.namespace.default()
  controller.heartbeatValue = 20000
  controller.resourceValue = "resource"
  return { controller, pending, subscriptions, timers,
    async resolve(index) { pending[index](consumer); await Promise.resolve(); await Promise.resolve() }
  }
}

for (const name of ["presence", "viewers"]) {
  test(`${name}: consumer tardivo dopo disconnect`, async () => {
    const h = await setup(name)
    h.controller.connect()
    h.controller.disconnect()
    await h.resolve(0)
    assert.equal(h.subscriptions.length, 0)
    assert.equal(h.timers.size, 0)
  })

  test(`${name}: reconnect scarta la promessa precedente`, async () => {
    const h = await setup(name)
    h.controller.connect()
    h.controller.disconnect()
    h.controller.connect()
    await h.resolve(1)
    await h.resolve(0)
    assert.equal(h.subscriptions.length, 1)
    h.controller.disconnect()
    assert.equal(h.subscriptions[0].unsubscriptions, 1)
    assert.equal(h.timers.size, 0)
  })

  test(`${name}: heartbeat soltanto sul canale confermato`, async () => {
    const h = await setup(name)
    h.controller.connect()
    await h.resolve(0)
    const subscription = h.subscriptions[0]
    assert.equal(h.timers.size, 0)
    subscription.callbacks.connected()
    subscription.callbacks.connected()
    assert.equal(h.timers.size, 1)
    for (const callback of h.timers.values()) callback()
    assert.deepEqual(subscription.beats, [name === "presence" ? "heartbeat" : "touch"])
    subscription.callbacks.disconnected()
    assert.equal(h.timers.size, 0)
    subscription.callbacks.connected()
    assert.equal(h.timers.size, 1)
    subscription.callbacks.rejected()
    assert.equal(h.timers.size, 0)
    h.controller.disconnect()
    subscription.callbacks.connected()
    assert.equal(h.timers.size, 0)
  })
}
