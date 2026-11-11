import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import test from "node:test"
const load = async path => import(`data:text/javascript;base64,${Buffer.from(await readFile(new URL(path, import.meta.url))).toString("base64")}`)
const THREE = await load("../../vendor/javascript/three.js")
const { createSpecialRooms, ROOM_CENTERS } = await load("../../app/javascript/coworker_office/rooms.js")

test("only explicitly active rooms are constructed, with duplicates and unknown IDs ignored", () => {
  assert.equal(createSpecialRooms(THREE).group.children.length, 0)
  const single = createSpecialRooms(THREE, ["archive", "archive", "unknown", "constructor", "toString"])
  assert.deepEqual([...single.centers.keys()], ["archive"])
  assert.ok(single.group.getObjectByName("room-archive"))
  assert.equal(single.group.getObjectByName("room-observatory"), undefined)
})

test("all specialist rooms remain proportionate, finite and clear of the existing office", () => {
  const rooms = createSpecialRooms(THREE, Object.keys(ROOM_CENTERS))
  for (const [id, center] of rooms.centers) {
    const room = rooms.group.getObjectByName(`room-${id}`)
    const bounds = new THREE.Box3().setFromObject(room)
    assert.ok(bounds.min.z >= -28 && bounds.max.z <= -13)
    assert.ok(bounds.max.y < 2.5)
    assert.ok(bounds.max.x - bounds.min.x < 13)
    assert.ok(Number.isFinite(bounds.min.x + bounds.max.y + bounds.max.z))
    assert.deepEqual(center.toArray(), [ROOM_CENTERS[id][0], 0, ROOM_CENTERS[id][1]])
    let meshes = 0
    room.traverse(node => { if (node.isMesh) meshes++ })
    assert.ok(meshes > 150)
  }
})
