import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import test from "node:test"
const load = async path => import(`data:text/javascript;base64,${Buffer.from(await readFile(new URL(path, import.meta.url))).toString("base64")}`)
const THREE = await load("../../vendor/javascript/three.js")
const { createOfficeDetails } = await load("../../app/javascript/coworker_office/details.js")
const snapshot = group => {
  const poses = []
  group.traverse(node => poses.push({ position: node.position.toArray(), rotation: node.rotation.toArray(), visible: node.visible, emissive: node.material?.emissiveIntensity }))
  return poses
}

test("seven distinct secrets are finite, furniture-sized and pickable in their own areas", () => {
  const details = createOfficeDetails(THREE)
  assert.deepEqual(details.discoveries.map(item => item.id), ["lucky_cat", "paper_plane", "tiny_arcade", "cookie_tin", "garden_snail", "server_robot", "secret_book"])
  details.group.updateMatrixWorld(true)
  for (const discovery of details.discoveries) {
    assert.equal(discovery.group.userData.discoveryId, discovery.id)
    assert.ok(details.animatedRoots.has(discovery.group))
    const bounds = new THREE.Box3().setFromObject(discovery.group), size = bounds.getSize(new THREE.Vector3())
    assert.ok(size.toArray().every(value => Number.isFinite(value) && value < 1.5), discovery.id)
    const center = bounds.getCenter(new THREE.Vector3())
    const ray = new THREE.Raycaster(center.clone().add(new THREE.Vector3(0, 3, 0)), new THREE.Vector3(0, -1, 0))
    assert.ok(ray.intersectObject(discovery.group, true).length > 0, discovery.id)
  }
  details.group.traverse(node => {
    if (node.geometry) assert.ok([...node.geometry.attributes.position.array].every(Number.isFinite))
  })
  details.dispose()
})

test("every secret reacts independently and resets after its short animation", () => {
  const details = createOfficeDetails(THREE)
  const resting = new Map(details.discoveries.map(({ id, group }) => [id, snapshot(group)]))
  for (const { id, group } of details.discoveries) {
    details.update(10, false)
    assert.equal(details.activate(id), true)
    details.update(11, false)
    assert.notDeepEqual(snapshot(group), resting.get(id), id)
    for (const other of details.discoveries.filter(item => item.id !== id)) assert.deepEqual(snapshot(other.group), resting.get(other.id), other.id)
    details.update(14, false)
    assert.deepEqual(snapshot(group), resting.get(id), id)
  }
  assert.equal(details.activate("missing"), false)
  details.dispose()
})

test("reduced motion reveals each discovery without continuous motion", () => {
  const details = createOfficeDetails(THREE)
  for (const { id } of details.discoveries) details.activate(id)
  details.update(0.5, true)
  const still = snapshot(details.group)
  details.update(1.5, true)
  assert.deepEqual(snapshot(details.group), still)
  details.dispose()
})

test("shared geometry and materials are disposed once even after repeated cleanup", () => {
  const details = createOfficeDetails(THREE), resources = new Set(), scene = new THREE.Scene()
  scene.add(details.group)
  details.group.traverse(node => { if (node.geometry) resources.add(node.geometry); if (node.material) resources.add(node.material) })
  const disposed = new Map([...resources].map(resource => [resource, 0]))
  for (const resource of resources) resource.addEventListener("dispose", () => disposed.set(resource, disposed.get(resource) + 1))
  details.dispose(); details.dispose()
  assert.ok([...disposed.values()].every(count => count === 1))
  assert.equal(details.group.parent, null)
  assert.equal(details.activate("lucky_cat"), false)
})
