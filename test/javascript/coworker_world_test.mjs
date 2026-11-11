import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import test from "node:test"
const load = async path => import(`data:text/javascript;base64,${Buffer.from(await readFile(new URL(path, import.meta.url))).toString("base64")}`)
const THREE = await load("../../vendor/javascript/three.js")
const { terrainHeight, roadZ, chunkKeys, createWorld, WORLD_RADIUS, landscapePocket } = await load("../../app/javascript/coworker_office/world.js")

test("campus, road and approach remain level while countryside has hills", () => {
  for (let x = -27; x <= 27; x++) for (let z = -28; z <= 26; z++) assert.equal(terrainHeight(x, z), -0.08)
  for (let x = -1000; x <= 1000; x += 5) assert.equal(terrainHeight(x, roadZ(x)), -0.08)
  for (let z = 11.4; z < roadZ(-29); z++) assert.equal(terrainHeight(-29, z), -0.08)
  assert.ok(terrainHeight(80, -80) > 1)
})

test("world coverage follows both positive and negative camera coordinates", () => {
  for (const [x, z] of [[0, 0], [-65, -65], [10000, -10000]]) {
    const keys = chunkKeys(x, z)
    assert.equal(keys.length, (WORLD_RADIUS * 2 + 1) ** 2)
    assert.equal(new Set(keys.map(key => key.join())).size, keys.length)
    assert.ok(keys.some(([cx, cz]) => cx === Math.floor(x / 64) && cz === Math.floor(z / 64)))
  }
})

test("chunks recycle with bounded geometry and preserve seam heights", () => {
  const world = createWorld(THREE)
  world.update(0, 0)
  const count = world.group.children.length
  const first = world.group.children[0]
  let disposed = false
  first.children[0].geometry.addEventListener("dispose", () => { disposed = true })
  world.update(10000, -10000)
  assert.equal(world.group.children.length, count)
  assert.equal(disposed, true)
  for (const tile of world.group.children) {
    const vertices = tile.children[0].geometry.attributes.position
    for (let i = 0; i < vertices.count; i++) assert.ok(Math.abs(vertices.getY(i) - terrainHeight(vertices.getX(i), vertices.getZ(i))) < 0.00001)
  }
  world.dispose()
  assert.equal(world.group.children.length, 0)
})


test("countryside details share rounded geometry and leave expansion rooms and routes clear", () => {
  const world = createWorld(THREE)
  world.update(0, 0)
  const names = new Set(), matrix = new THREE.Matrix4(), position = new THREE.Vector3()
  let trunkCount = 0, crownCount = 0, texture = null
  for (const tile of world.group.children) {
    const ground = tile.children[0]
    texture ||= ground.material.map
    assert.equal(ground.material.map, texture)
    assert.equal(texture.isDataTexture, true)
    tile.traverse(node => {
      if (!node.isInstancedMesh) return
      names.add(node.name)
      if (node.name === "world-tree-trunks") trunkCount += node.count
      if (node.name === "world-tree-crowns") crownCount += node.count
      for (let i = 0; i < node.count; i++) {
        node.getMatrixAt(i, matrix)
        assert.ok(matrix.elements.every(Number.isFinite))
        position.setFromMatrixPosition(matrix)
        if (["world-tree-trunks", "world-shrubs", "world-grass-tufts", "world-wildflowers", "world-stones"].includes(node.name)) {
          const pocket = node.name !== "world-tree-trunks" && landscapePocket(position.x, position.z)
          assert.ok(pocket || !(Math.abs(position.x) < 32 && position.z > -33 && position.z < 31))
          assert.ok(Math.abs(position.z - roadZ(position.x)) > (pocket ? 5.2 : 6))
        }
      }
    })
  }
  assert.equal(crownCount, trunkCount * 5)
  for (const name of ["world-shrubs", "world-stones", "world-wildflowers", "world-grass-tufts", "world-road-posts"]) assert.ok(names.has(name))
  let textureDisposed = false, sharedDisposed = false
  texture.addEventListener("dispose", () => { textureDisposed = true })
  world.group.getObjectByName("world-tree-crowns").geometry.addEventListener("dispose", () => { sharedDisposed = true })
  world.update(10000, 10000)
  assert.equal(textureDisposed, false)
  assert.equal(sharedDisposed, false)
  world.dispose()
  assert.equal(textureDisposed, true)
  assert.equal(sharedDisposed, true)
})


test("visible perimeter has planted pockets while rooms and entry remain clear", () => {
  const world = createWorld(THREE)
  world.update(0, 0)
  const matrix = new THREE.Matrix4(), position = new THREE.Vector3(), areas = new Set()
  world.group.traverse(node => {
    if (node.name !== "world-shrubs") return
    for (let i = 0; i < node.count; i++) {
      node.getMatrixAt(i, matrix); position.setFromMatrixPosition(matrix)
      if (!landscapePocket(position.x, position.z)) continue
      areas.add(position.z < -28 ? "north" : position.z > 25 ? "south" : position.x < 0 ? "west" : "east")
    }
  })
  assert.deepEqual([...areas].sort(), ["east", "north", "south", "west"])
  for (const [x, z] of [[0, -23], [0, 0], [-29, 20], [25, 11.4], [-24, 11.4], [0, 35]]) assert.equal(landscapePocket(x, z), false)
  world.dispose()
})
