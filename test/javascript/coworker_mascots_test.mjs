import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import test from "node:test"

const load = async path => import(`data:text/javascript;base64,${Buffer.from(await readFile(new URL(path, import.meta.url))).toString("base64")}`)
const THREE = await load("../../vendor/javascript/three.js")
const { createMascot, mascotChoice, animateMascot } = await load("../../app/javascript/coworker_office/mascots.js")

test("invalid or missing browser choices use the same cloud default as the gallery", () => {
  for (const value of [null, undefined, "", "00", "21", "1", "../01", "03.webp"]) assert.equal(mascotChoice(value), "01")
})

test("expressions blink, work and greet without leaving closed eyes under reduced motion", () => {
  const mascot = createMascot(THREE, "01")
  const state = { time: 0.09, phase: 0, walking: false, working: false, greeting: true, reducedMotion: false }
  animateMascot(mascot, state)
  assert.ok(mascot.eyes.every(eye => eye.scale.y < 0.1))
  assert.ok(mascot.arms[1].rotation.z > 1.8)
  animateMascot(mascot, { ...state, greeting: false, working: true, time: 2 })
  assert.ok(mascot.arms.every(arm => arm.rotation.x < -0.5))
  animateMascot(mascot, { ...state, reducedMotion: true })
  assert.ok(mascot.eyes.every(eye => eye.scale.y === 1))
  assert.ok(mascot.arms.every(arm => arm.rotation.x === 0 && arm.rotation.z === 0))
})

test("all twenty gallery choices produce finite, pickable 3D characters within the walking envelope", () => {
  for (let index = 1; index <= 20; index++) {
    const id = String(index).padStart(2, "0")
    assert.equal(mascotChoice(id), id)
    const { group, arms } = createMascot(THREE, id)
    group.updateMatrixWorld(true)
    const bounds = new THREE.Box3().setFromObject(group), size = bounds.getSize(new THREE.Vector3())
    assert.ok(size.toArray().every(Number.isFinite), id)
    assert.ok(size.x < 2.2 && size.y < 2.7 && size.z < 1.6, id)
    assert.equal(arms.length, 2)
    const ray = new THREE.Raycaster(new THREE.Vector3(0, 1, 5), new THREE.Vector3(0, 0, -1))
    assert.ok(ray.intersectObject(group, true).length > 0, id)
    group.traverse(node => {
      if (!node.geometry) return
      assert.ok([...node.geometry.attributes.position.array].every(Number.isFinite), `${id} geometry`)
    })
  }
})
