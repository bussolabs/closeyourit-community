// Decorative wildlife and cafe behaviour share the office's animation clock (CYRA-1283).
export function fishPose(time, index, observer = null) {
  const angle = time * (0.26 + index * 0.025) + index * 1.8
  const radius = 0.85 + (index % 3) * 0.35
  const near = observer && Math.hypot(observer.x + 3.5, observer.z - 21) < 5
  const direction = near ? Math.atan2(observer.z - 21, observer.x + 3.5) : 0
  const centerX = near ? Math.cos(direction) * 1.1 : 0, centerZ = near ? Math.sin(direction) * 1.1 : 0
  const orbit = near ? 0.35 + index * 0.07 : radius
  return { x: -3.5 + centerX + Math.cos(angle) * orbit, z: 21 + centerZ + Math.sin(angle) * orbit * 0.78,
    heading: Math.atan2(-Math.sin(angle), Math.cos(angle) * 0.78) }
}

export function birdPass(time) {
  const phase = time % 32
  return { visible: phase < 8, progress: phase / 8 }
}

export function umbrellaOccupied(wasOpen, table, positions) {
  const radius = wasOpen ? 4.6 : 3.6
  return positions.some(position => Math.hypot(position.x - table.x, position.z - table.z) <= radius + 1e-9)
}

export function createUmbrella(THREE, { x, z, shade, metal, alwaysOpen = false }) {
  const group = new THREE.Group(), canopy = new THREE.Group()
  group.name = "cafe-umbrella"
  group.position.set(x, 2.8, z)
  group.add(canopy)
  const fabric = new THREE.Mesh(new THREE.ConeGeometry(1.5, 0.6, 32), shade)
  fabric.position.y = -0.3
  fabric.castShadow = fabric.receiveShadow = true
  canopy.add(fabric)
  for (let i = 0; i < 8; i++) {
    const angle = i * Math.PI / 4
    const end = new THREE.Vector3(Math.cos(angle) * 1.43, -0.58, Math.sin(angle) * 1.43)
    const rib = new THREE.Mesh(new THREE.CylinderGeometry(0.012, 0.012, end.length(), 6), metal)
    rib.position.copy(end).multiplyScalar(0.5)
    rib.quaternion.setFromUnitVectors(new THREE.Vector3(0, 1, 0), end.clone().normalize())
    canopy.add(rib)
  }
  let occupied = alwaysOpen, openness = alwaysOpen ? 1 : 0
  function pose() {
    const width = 0.12 + openness * 0.88
    canopy.scale.set(width, 2.3 - openness * 1.3, width)
  }
  pose()
  return {
    group,
    get openness() { return openness },
    update(positions, delta, reducedMotion, time = 0) {
      occupied = alwaysOpen || umbrellaOccupied(occupied, { x, z }, positions)
      const target = occupied ? 1 : 0
      openness = reducedMotion ? target : openness + (target - openness) * (1 - Math.exp(-3 * Math.min(delta, 0.1)))
      if (Math.abs(target - openness) < 0.001) openness = target
      pose()
      canopy.rotation.z = reducedMotion ? 0 : Math.sin(time * 0.65 + x) * 0.012 * openness
      canopy.rotation.x = reducedMotion ? 0 : Math.cos(time * 0.5 + z) * 0.008 * openness
    }
  }
}

export function createGardenLife(THREE) {
  const group = new THREE.Group()
  group.name = "garden-life"
  const sphere = new THREE.SphereGeometry(1, 16, 10)
  const material = color => new THREE.MeshStandardMaterial({ color, roughness: 0.78 })
  const orange = material("#e79a43"), cream = material("#fff0cf"), ink = material("#302a32")
  const brown = material("#ae7044"), tailBrown = material("#c98a51"), blue = material("#739eae")
  function oval(parent, mat, x, y, z, sx, sy, sz) {
    const mesh = new THREE.Mesh(sphere, mat)
    mesh.position.set(x, y, z)
    mesh.scale.set(sx, sy, sz)
    mesh.castShadow = mesh.receiveShadow = true
    parent.add(mesh)
    return mesh
  }
  const fishes = Array.from({ length: 5 }, (_, index) => {
    const fish = new THREE.Group(), tail = new THREE.Group()
    fish.name = `pond-fish-${index}`
    const mat = index % 2 ? cream : orange
    oval(fish, mat, 0, 0, 0, 0.12, 0.055, 0.27)
    oval(fish, index % 2 ? orange : cream, 0, 0.035, 0.04, 0.09, 0.025, 0.10)
    tail.position.z = -0.24
    fish.add(tail)
    for (const side of [-1, 1]) {
      oval(tail, mat, side * 0.07, 0, -0.07, 0.10, 0.025, 0.13).rotation.y = side * 0.5
      oval(fish, ink, side * 0.07, 0.025, 0.18, 0.018, 0.018, 0.018)
    }
    // Thin, unshadowed silhouettes at the waterline remain legible through the pond material.
    fish.traverse(node => { node.castShadow = false })
    group.add(fish)
    return { fish, tail }
  })
  const flock = new THREE.Group()
  flock.name = "passing-birds"
  group.add(flock)
  const birds = Array.from({ length: 3 }, (_, index) => {
    const bird = new THREE.Group(), wings = []
    bird.position.set(-index * 1.1, index * 0.2, index % 2 ? 0.9 : -0.9)
    oval(bird, blue, 0, 0, 0, 0.12, 0.12, 0.28)
    oval(bird, cream, 0, -0.04, 0.12, 0.10, 0.10, 0.16)
    oval(bird, orange, 0, 0, 0.34, 0.045, 0.04, 0.10)
    for (const side of [-1, 1]) {
      const wing = new THREE.Group()
      oval(wing, blue, side * 0.28, 0, -0.03, 0.36, 0.045, 0.17)
      bird.add(wing); wings.push(wing)
    }
    flock.add(bird)
    return { bird, wings }
  })
  birds.forEach(({ bird }) => {
    const from = new THREE.Vector3(-20.5, 2.1, 22)
    const to = bird.position.clone().add(new THREE.Vector3(-20.5, 2.66, 22))
    const branch = new THREE.Mesh(new THREE.CylinderGeometry(0.04, 0.07, from.distanceTo(to), 6), brown)
    branch.position.copy(from).add(to).multiplyScalar(0.5)
    branch.quaternion.setFromUnitVectors(new THREE.Vector3(0, 1, 0), to.sub(from).normalize())
    group.add(branch)
  })
  const squirrels = [[-20, 20.7], [-9, 14.3]].map(([x, z], index) => {
    const squirrel = new THREE.Group(), tail = new THREE.Group()
    squirrel.name = `park-squirrel-${index}`
    oval(squirrel, brown, 0, 0.25, 0, 0.18, 0.25, 0.28)
    oval(squirrel, cream, 0, 0.23, 0.21, 0.12, 0.17, 0.07)
    oval(squirrel, brown, 0, 0.48, 0.23, 0.18, 0.18, 0.18)
    oval(squirrel, ink, 0, 0.44, 0.40, 0.035, 0.03, 0.035)
    for (const side of [-1, 1]) {
      oval(squirrel, brown, side * 0.12, 0.65, 0.20, 0.065, 0.11, 0.06)
      oval(squirrel, ink, side * 0.13, 0.51, 0.34, 0.025, 0.028, 0.02)
      oval(squirrel, brown, side * 0.14, 0.06, 0.13, 0.09, 0.06, 0.15)
      oval(squirrel, brown, side * 0.14, 0.25, 0.24, 0.055, 0.11, 0.055).rotation.x = -0.6
    }
    tail.position.set(0, 0.16, -0.20)
    oval(tail, tailBrown, 0, 0.25, -0.17, 0.17, 0.35, 0.20).rotation.x = -0.5
    oval(tail, tailBrown, 0, 0.53, -0.15, 0.18, 0.19, 0.19)
    squirrel.add(tail)
    squirrel.position.set(x, 0.06, z)
    group.add(squirrel)
    return { squirrel, tail, x, z }
  })
  let lastTime = 0
  function update(time, reducedMotion, positions = []) {
    const delta = Math.min(0.1, Math.max(0, time - lastTime))
    lastTime = time
    if (reducedMotion) { flock.visible = false; return }
    fishes.forEach(({ fish, tail }, index) => {
      const observer = positions.find(position => Math.hypot(position.x + 3.5, position.z - 21) < 5)
      const pose = fishPose(time, index, observer)
      const surfacePhase = (time + index * 4) % 14
      const rise = index < 3 && surfacePhase < 0.8 ? Math.sin(surfacePhase / 0.8 * Math.PI) * 0.04 : 0
      const blend = time === 0 ? 1 : 1 - Math.exp(-delta * 2)
      fish.position.x += (pose.x - fish.position.x) * blend
      fish.position.z += (pose.z - fish.position.z) * blend
      fish.position.y = 0.10 + rise
      fish.rotation.y = pose.heading
      tail.rotation.y = Math.sin(time * 7 + index) * 0.35
    })
    const phase = time % 32
    const perched = phase >= 11 && phase < 28
    flock.visible = true
    const start = new THREE.Vector3(-28, 6, -6), end = new THREE.Vector3(28, 6, 14), branch = new THREE.Vector3(-20.5, 2.8, 22)
    let from, to, progress
    if (phase < 8) { from = start; to = end; progress = phase / 8 }
    else if (phase < 11) { from = end; to = branch; progress = (phase - 8) / 3 }
    else if (perched) { from = branch; to = branch; progress = 0 }
    else { from = branch; to = start; progress = (phase - 28) / 4 }
    flock.position.copy(from).lerp(to, progress)
    if (!perched) flock.position.y += Math.sin(progress * Math.PI) * 2
    flock.rotation.y = perched ? 0 : Math.atan2(to.x - from.x, to.z - from.z)
    birds.forEach(({ bird, wings }, index) => {
      bird.rotation.y = perched ? Math.sin(time * 0.7 + index) * 0.3 : 0
      wings.forEach((wing, side) => {
        wing.rotation.z = (perched ? 1.2 : Math.sin(time * 9 + index * 0.8) * 0.65) * (side ? 1 : -1)
      })
    })
    squirrels.forEach(({ squirrel, tail, x, z }, index) => {
      const nearby = positions.find(position => Math.hypot(position.x - squirrel.position.x, position.z - squirrel.position.z) < 2.8)
      if (nearby) {
        squirrel.rotation.y = Math.atan2(nearby.x - squirrel.position.x, nearby.z - squirrel.position.z)
        return
      }
      squirrel.userData.time = (squirrel.userData.time || 0) + delta
      const phase = (squirrel.userData.time + index * 9) % 24
      const outward = phase < 4, returning = phase >= 12 && phase < 16
      const distance = outward ? phase / 4 : returning ? 1 - (phase - 12) / 4 : phase < 12 ? 1 : 0
      squirrel.position.set(x + distance * 2.7, 0.06 + (outward || returning ? Math.abs(Math.sin(time * 12)) * 0.10 : 0), z + distance * 0.65)
      squirrel.rotation.y = outward ? 1.33 : returning ? -1.81 : 0.4
      tail.rotation.z = Math.sin(time * 2 + index) * 0.08
    })
  }
  update(0, false)
  return { group, update }
}
