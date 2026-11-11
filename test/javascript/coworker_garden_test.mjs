import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import test from "node:test"

const load = async path => import(`data:text/javascript;base64,${Buffer.from(await readFile(new URL(path, import.meta.url))).toString("base64")}`)
const THREE = await load("../../vendor/javascript/three.js")
const { fishPose, birdPass, umbrellaOccupied, createGardenLife, createUmbrella } = await load("../../app/javascript/coworker_office/garden.js")

test("fish stay inside the pond, including the full length of their bodies", () => {
  for (let i = 0; i < 5; i++) for (let t = 0; t < 240; t += 0.3) {
    const p = fishPose(t, i)
    assert.ok(Math.hypot(p.x + 3.5, p.z - 21) + 0.40 < 2.5)
    assert.ok(Number.isFinite(p.heading))
  }
})

test("birds pass occasionally and are absent between flights", () => {
  assert.equal(birdPass(0).visible, true)
  assert.equal(birdPass(7.9).visible, true)
  assert.equal(birdPass(8).visible, false)
  assert.equal(birdPass(31.9).visible, false)
  assert.equal(birdPass(32).visible, true)
})

test("umbrellas use arrival and departure radii without flickering at the boundary", () => {
  const table = { x: 15, z: 19 }
  assert.equal(umbrellaOccupied(false, table, []), false)
  assert.equal(umbrellaOccupied(false, table, [{ x: 15, z: 15.4 }]), true)
  assert.equal(umbrellaOccupied(false, table, [{ x: 15, z: 15.39 }]), false)
  assert.equal(umbrellaOccupied(true, table, [{ x: 15, z: 14.5 }]), true)
  assert.equal(umbrellaOccupied(true, table, [{ x: 15, z: 14.3 }]), false)
  assert.equal(umbrellaOccupied(false, table, [{ x: -7, z: -2 }, { x: 15, z: 17 }]), true)
})

test("garden motion freezes for reduced motion while animals remain present", () => {
  const garden = createGardenLife(THREE)
  garden.update(3, false)
  const fish = garden.group.getObjectByName("pond-fish-0")
  const position = fish.position.clone()
  garden.update(20, true)
  assert.deepEqual(fish.position.toArray(), position.toArray())
  assert.equal(garden.group.getObjectByName("passing-birds").visible, false)
})

test("umbrellas open on arrival, close after departure, and snap with reduced motion", () => {
  const shade = new THREE.MeshStandardMaterial(), metal = new THREE.MeshStandardMaterial()
  const umbrella = createUmbrella(THREE, { x: 15, z: 19, shade, metal })
  umbrella.update([], 1, false)
  assert.equal(umbrella.openness, 0)
  umbrella.update([{ x: 15, z: 17 }], 0.1, false)
  assert.ok(umbrella.openness > 0 && umbrella.openness < 1)
  umbrella.update([{ x: 15, z: 17 }], 1, true)
  assert.equal(umbrella.openness, 1)
  umbrella.update([], 1, true)
  assert.equal(umbrella.openness, 0)
})

test("fish gather on the observer's side without leaving the pond", () => {
  for (const observer of [{ x: -3.5, z: 17.5 }, { x: 0, z: 21 }, { x: -7, z: 21 }]) {
    let x = 0, z = 0
    for (let i = 0; i < 5; i++) for (let time = 0; time < 60; time += 0.2) {
      const pose = fishPose(time, i, observer)
      assert.ok(Math.hypot(pose.x + 3.5, pose.z - 21) + 0.4 < 2.5)
      x += pose.x + 3.5; z += pose.z - 21
    }
    assert.ok(x * (observer.x + 3.5) + z * (observer.z - 21) > 0)
  }
  assert.deepEqual(fishPose(2, 1, { x: 100, z: 100 }), fishPose(2, 1))
})

test("squirrels pause near a Puck and resume without jumping", () => {
  const garden = createGardenLife(THREE)
  garden.update(0.1, false)
  const squirrel = garden.group.getObjectByName("park-squirrel-0")
  const before = squirrel.position.clone()
  for (let i = 2; i < 30; i++) garden.update(i / 10, false, [before])
  assert.deepEqual(squirrel.position.toArray(), before.toArray())
  garden.update(3, false, [])
  assert.ok(squirrel.position.distanceTo(before) < 0.2)
  assert.ok(squirrel.position.distanceTo(before) > 0)
})

test("birds land continuously and remain on branches between flights", () => {
  const garden = createGardenLife(THREE)
  const flock = garden.group.getObjectByName("passing-birds")
  for (const boundary of [8, 11, 28, 32]) {
    garden.update(boundary - 0.001, false)
    const before = flock.position.clone()
    garden.update(boundary, false)
    assert.ok(flock.position.distanceTo(before) < 0.03)
  }
  garden.update(15, false)
  const resting = flock.position.clone()
  garden.update(25, false)
  assert.deepEqual(flock.position.toArray(), resting.toArray())
})
