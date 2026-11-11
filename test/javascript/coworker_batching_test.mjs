import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import test from "node:test"
const load = async path => import(`data:text/javascript;base64,${Buffer.from(await readFile(new URL(path, import.meta.url))).toString("base64")}`)
const THREE = await load("../../vendor/javascript/three.js")
const { batchStaticMeshes } = await load("../../app/javascript/coworker_office/batching.js")

test("batching preserves world transforms and unique children while excluding animated subtrees", () => {
  const scene = new THREE.Scene(), room = new THREE.Group(), animated = new THREE.Group()
  room.position.set(4, 0, -3)
  scene.add(room, animated)
  const geometry = new THREE.BoxGeometry(1, 1, 1), material = new THREE.MeshStandardMaterial()
  const nodes = Array.from({ length: 3 }, (_, index) => {
    const node = new THREE.Mesh(geometry, material)
    node.position.x = index
    room.add(node)
    return node
  })
  const child = new THREE.Mesh(new THREE.SphereGeometry(0.2), material)
  child.position.y = 2
  nodes[0].add(child)
  const moving = new THREE.Mesh(geometry, material)
  animated.add(moving)
  assert.equal(batchStaticMeshes(THREE, scene, new Set([animated])), 2)
  const batch = scene.getObjectByName("static-office-details")
  assert.equal(batch.count, 3)
  const matrix = new THREE.Matrix4()
  batch.getMatrixAt(2, matrix)
  assert.deepEqual(new THREE.Vector3().setFromMatrixPosition(matrix).toArray(), [6, 0, -3])
  assert.deepEqual(child.getWorldPosition(new THREE.Vector3()).toArray(), [4, 2, -3])
  assert.equal(child.parent, scene)
  assert.equal(moving.parent, animated)
})

test("transparent surfaces and small groups are never batched", () => {
  const scene = new THREE.Scene(), geometry = new THREE.BoxGeometry(1, 1, 1)
  const material = new THREE.MeshStandardMaterial({ transparent: true, opacity: 0.5 })
  for (let i = 0; i < 4; i++) scene.add(new THREE.Mesh(geometry, material))
  assert.equal(batchStaticMeshes(THREE, scene, new Set()), 0)
  assert.equal(scene.children.length, 4)
})
