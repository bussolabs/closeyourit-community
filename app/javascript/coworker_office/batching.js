// Repeated static details share draw calls; animated and transparent meshes keep their own nodes.
export function batchStaticMeshes(THREE, scene, animatedRoots) {
  const batches = new Map()
  scene.updateMatrixWorld(true)
  scene.traverse(node => {
    if (!node.isMesh || node.material.transparent || Array.isArray(node.material)) return
    for (let parent = node; parent; parent = parent.parent) if (animatedRoots.has(parent)) return
    const key = `${node.geometry.uuid}:${node.material.uuid}:${node.castShadow}:${node.receiveShadow}`
    if (!batches.has(key)) batches.set(key, [])
    batches.get(key).push(node)
  })
  let savedDraws = 0
  batches.forEach(nodes => {
    if (nodes.length < 3) return
    const first = nodes[0]
    const mesh = new THREE.InstancedMesh(first.geometry, first.material, nodes.length)
    mesh.name = "static-office-details"
    mesh.castShadow = first.castShadow
    mesh.receiveShadow = first.receiveShadow
    nodes.forEach((node, index) => mesh.setMatrixAt(index, node.matrixWorld))
    mesh.instanceMatrix.needsUpdate = true
    mesh.computeBoundingSphere()
    nodes.forEach(node => {
      for (const child of [...node.children]) scene.attach(child)
      node.removeFromParent()
    })
    scene.add(mesh)
    savedDraws += nodes.length - 1
  })
  return savedDraws
}
