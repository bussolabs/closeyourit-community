// Recycled chunks share a deterministic height field: moving the camera reveals more countryside.
export const CHUNK_SIZE = 64
export const WORLD_RADIUS = 4
export const roadZ = x => 35 + Math.sin(x / 55) * 5
const smooth = value => { const t = Math.max(0, Math.min(1, value)); return t * t * (3 - 2 * t) }
export function terrainHeight(x, z) {
  const campusDistance = Math.hypot(Math.max(0, Math.abs(x) - 28), Math.max(0, Math.abs(z + 0.5) - 27.5))
  const approachDistance = Math.hypot(x + 29, Math.max(0, 11.4 - z, z - roadZ(-29)))
  const roadDistance = Math.abs(z - roadZ(x))
  const hills = 3.8 + Math.sin(x / 23 + z / 31) * 2.2 + Math.sin(x / 47 - z / 19) * 1.6 + Math.cos(z / 13) * 0.7
  return -0.08 + hills * smooth(campusDistance / 16) * smooth((roadDistance - 5) / 15) * smooth((approachDistance - 2) / 6)
}

// The approach follows the road shoulder and the west side of the campus, clear of the pond.
export const OFFICE_APPROACH = [[-72, roadZ(-72)], [-48, roadZ(-48)], [-29, roadZ(-29)], [-29, 11.4], [-11.25, 11.4], [-11.25, 1.75], [-2, 1.75]]

// Perimeter pockets dress the visible campus without blocking rooms, the access lane, or roads.
export function landscapePocket(x, z) {
  const side = (x >= -26 && x <= -23 || x >= 24 && x <= 27) && z >= -10 && z <= 24 && (z < 9.6 || z > 13.2)
  const south = x >= -22 && x <= 20 && z >= 25.5 && z <= 28
  const north = x >= -22 && x <= 22 && z >= -31 && z <= -28
  return (side || south || north) && Math.abs(z - roadZ(x)) > 5.3
}

export function chunkKeys(x, z) {
  const cx = Math.floor(x / CHUNK_SIZE), cz = Math.floor(z / CHUNK_SIZE)
  const keys = []
  for (let dz = -WORLD_RADIUS; dz <= WORLD_RADIUS; dz++) for (let dx = -WORLD_RADIUS; dx <= WORLD_RADIUS; dx++) keys.push([cx + dx, cz + dz])
  return keys
}

export function createWorld(THREE) {
  const group = new THREE.Group()
  group.name = "surrounding-world"
  const grassPixels = new Uint8Array(64 * 64 * 4)
  for (let i = 0; i < 64 * 64; i++) {
    const grain = 232 + Math.floor((Math.sin(i * 12.9898) * 43758.5453 % 1 + 1) * 8)
    grassPixels.set([grain, grain, grain, 255], i * 4)
  }
  const grassTexture = new THREE.DataTexture(grassPixels, 64, 64)
  grassTexture.wrapS = grassTexture.wrapT = THREE.RepeatWrapping
  grassTexture.repeat.set(32, 32)
  grassTexture.magFilter = THREE.LinearFilter
  grassTexture.minFilter = THREE.LinearMipmapLinearFilter
  grassTexture.generateMipmaps = true
  grassTexture.needsUpdate = true
  const material = new THREE.MeshStandardMaterial({ vertexColors: true, map: grassTexture, roughness: 1 })
  const roadMaterial = new THREE.MeshStandardMaterial({ color: "#777b79", roughness: 0.95 })
  const shoulderMaterial = new THREE.MeshStandardMaterial({ color: "#d5c7a3", roughness: 1 })
  const markingMaterial = new THREE.MeshStandardMaterial({ color: "#eee5cf", roughness: 1 })
  const chunks = new Map()
  const trunkGeometry = new THREE.CylinderGeometry(0.16, 0.25, 1.9, 6)
  const crownGeometry = new THREE.SphereGeometry(1, 12, 8)
  const trunkMaterial = new THREE.MeshStandardMaterial({ color: "#93714d", roughness: 1 })
  const crownMaterial = new THREE.MeshStandardMaterial({ color: "#829764", roughness: 1 })
  const stoneGeometry = new THREE.IcosahedronGeometry(1, 1)
  const postGeometry = new THREE.BoxGeometry(1, 1, 1)
  const bladeGeometry = new THREE.BufferGeometry()
  bladeGeometry.setAttribute("position", new THREE.Float32BufferAttribute([-0.06, 0, 0, 0.06, 0, 0, 0.01, 0.38, 0.06, 0, 0, -0.06, 0, 0, 0.06, 0.06, 0.30, 0.01], 3))
  bladeGeometry.computeVertexNormals()
  const stoneMaterial = new THREE.MeshStandardMaterial({ color: "#c3c3ae", roughness: 1 })
  const shrubMaterial = new THREE.MeshStandardMaterial({ color: "#879e67", roughness: 1 })
  const grassMaterial = new THREE.MeshStandardMaterial({ color: "#7f9c64", roughness: 1, side: THREE.DoubleSide })
  const petalMaterial = new THREE.MeshStandardMaterial({ color: "#f1ddaa", roughness: 1 })
  const petalPink = new THREE.Color("#d8b5c6"), petalCream = new THREE.Color("#f3e8c4")
  const matrix = new THREE.Object3D(), color = new THREE.Color()
  const sharedResources = [trunkGeometry, crownGeometry, stoneGeometry, postGeometry, bladeGeometry, material, roadMaterial,
    shoulderMaterial, markingMaterial, trunkMaterial, crownMaterial, stoneMaterial, shrubMaterial, grassMaterial, petalMaterial, grassTexture]
  const random = seed => { const value = Math.sin(seed * 12.9898) * 43758.5453; return value - Math.floor(value) }
  function protectedGround(x, z) {
    return Math.abs(x) < 33 && z > -34 && z < 32 || Math.abs(z - roadZ(x)) < 7 || Math.abs(x + 29) < 3 && z > 10 && z < 35
  }
  function instances(tile, name, geometry, mat, locations) {
    if (!locations.length) return
    const mesh = new THREE.InstancedMesh(geometry, mat, locations.length)
    mesh.name = name
    mesh.receiveShadow = true
    locations.forEach(([x, y, z, sx, sy, sz, angle = 0, tint], i) => {
      matrix.position.set(x, y, z); matrix.scale.set(sx, sy, sz); matrix.rotation.set(0, angle, 0); matrix.updateMatrix()
      mesh.setMatrixAt(i, matrix.matrix)
      if (tint) mesh.setColorAt(i, tint)
    })
    tile.add(mesh)
  }
  function ribbon(x0, x1, width, mat, y) {
    const vertices = [], indices = []
    for (let i = 0; i <= 32; i++) {
      const x = x0 + (x1 - x0) * i / 32, z = roadZ(x)
      vertices.push(x, y, z - width, x, y, z + width)
      if (i < 32) { const n = i * 2; indices.push(n, n + 1, n + 2, n + 1, n + 3, n + 2) }
    }
    const geometry = new THREE.BufferGeometry()
    geometry.setAttribute("position", new THREE.Float32BufferAttribute(vertices, 3))
    geometry.setIndex(indices); geometry.computeVertexNormals()
    const mesh = new THREE.Mesh(geometry, mat)
    mesh.receiveShadow = true
    return mesh
  }
  function build(cx, cz) {
    const tile = new THREE.Group(), x0 = cx * CHUNK_SIZE, z0 = cz * CHUNK_SIZE
    const geometry = new THREE.PlaneGeometry(CHUNK_SIZE, CHUNK_SIZE, 32, 32)
    geometry.rotateX(-Math.PI / 2)
    const positions = geometry.attributes.position, colors = []
    for (let i = 0; i < positions.count; i++) {
      const x = positions.getX(i) + x0 + CHUNK_SIZE / 2, z = positions.getZ(i) + z0 + CHUNK_SIZE / 2
      positions.setXYZ(i, x, terrainHeight(x, z), z)
      const variation = (Math.sin(x / 17) * Math.cos(z / 21) + 1) / 2
      color.set("#9db580").lerp(new THREE.Color("#8fa775"), variation)
      colors.push(color.r, color.g, color.b)
    }
    geometry.setAttribute("color", new THREE.Float32BufferAttribute(colors, 3))
    geometry.computeVertexNormals()
    const ground = new THREE.Mesh(geometry, material)
    ground.receiveShadow = true
    tile.add(ground)
    if (cz === 0) {
      tile.add(ribbon(x0, x0 + CHUNK_SIZE, 4.1, shoulderMaterial, -0.035), ribbon(x0, x0 + CHUNK_SIZE, 3.2, roadMaterial, -0.015))
      for (let x = x0; x < x0 + CHUNK_SIZE; x += 8) tile.add(ribbon(x + 1, x + 4, 0.055, markingMaterial, 0.005))
    }
    const trunks = [], crowns = [], shrubs = [], stones = [], flowers = [], tufts = []
    const nearCampus = Math.abs(x0 + 32) < 100 && Math.abs(z0 + 32) < 100
    const count = nearCampus ? 24 : 10
    for (let i = 0; i < count; i++) {
      const seed = cx * 173 + cz * 79 + i * 37
      const fraction = random(seed), x = x0 + 5 + fraction * 54, z = z0 + 5 + random(seed + 1) * 54
      if (protectedGround(x, z)) continue
      const y = terrainHeight(x, z), scale = 0.65 + fraction * 0.6
      trunks.push([x, y + 0.95 * scale, z, scale, scale, scale])
      for (let lobe = 0; lobe < 5; lobe++) {
        const angle = lobe * Math.PI / 2
        const offset = lobe === 4 ? 0 : 0.67 * scale
        crowns.push([x + Math.cos(angle) * offset, y + (lobe === 4 ? 3.2 : 2.5) * scale, z + Math.sin(angle) * offset,
          scale * 0.95, scale * (lobe === 4 ? 0.95 : 1.1), scale * 0.95, 0])
      }
    }
    if (nearCampus) {
      // Small drifts use coherent clusters rather than scattering isolated props across every metre.
      for (let i = 0; i < 60; i++) {
        const seed = cx * 317 + cz * 191 + i * 43
        const x = x0 + 3 + random(seed) * 58, z = z0 + 3 + random(seed + 1) * 58
        if (protectedGround(x, z)) continue
        const y = terrainHeight(x, z), size = 0.22 + random(seed + 2) * 0.35
        if (i % 3 === 0) {
          for (let j = 0; j < 3; j++) shrubs.push([x + j * 0.3, y + size * 0.6, z + Math.sin(j) * 0.25, size, size * 0.7, size * 0.85])
          stones.push([x - 0.6, y + size * 0.25, z, size * 0.8, size * 0.45, size * 0.6, seed])
        }
        for (let j = 0; j < 9; j++) {
          const angle = random(seed + j + 3) * Math.PI * 2, radius = random(seed + j + 7) * 1.2
          const dx = x + Math.cos(angle) * radius, dz = z + Math.sin(angle) * radius
          if (protectedGround(dx, dz)) continue
          const groundY = terrainHeight(dx, dz)
          tufts.push([dx, groundY, dz, 0.65, 0.65 + random(seed + j) * 0.6, 0.65, angle])
          if (i % 2 === 0) flowers.push([dx, groundY + 0.22, dz, 0.085, 0.055, 0.085, 0, i % 4 ? petalPink : petalCream])
        }
      }
    }
    if (nearCampus) {
      const pockets = []
      for (const x of [-24.5, 25.5]) for (const z of [-8.4, -3, 3.2, 7.5, 15, 20.7, 23]) pockets.push([x, z])
      for (let x = -20; x <= 19; x += 5.6) { pockets.push([x, 26.6]); pockets.push([x, -29.5]) }
      pockets.forEach(([x, z], index) => {
        if (Math.floor(x / CHUNK_SIZE) !== cx || Math.floor(z / CHUNK_SIZE) !== cz) return
        const seed = index * 83 + 19
        for (let j = 0; j < 6; j++) {
          const angle = j * 2.4 + random(seed), radius = 0.3 + random(seed + j + 1) * 0.85
          const dx = x + Math.cos(angle) * radius, dz = z + Math.sin(angle) * radius
          if (!landscapePocket(dx, dz)) continue
          const y = terrainHeight(dx, dz), size = 0.24 + random(seed + j + 4) * 0.24
          shrubs.push([dx, y + size * 0.5, dz, size * 1.2, size * 0.7, size])
          if (j % 2 === 0) stones.push([dx + 0.12, y + 0.07, dz, 0.21, 0.12, 0.17, angle])
          for (let bloom = 0; bloom < 5; bloom++) {
            const a = bloom * Math.PI * 0.4, bx = dx + Math.cos(a) * size * 0.55, bz = dz + Math.sin(a) * size * 0.55
            if (!landscapePocket(bx, bz)) continue
            flowers.push([bx, y + size * 1.08, bz, 0.085, 0.065, 0.085, 0, index % 3 ? petalCream : petalPink])
          }
          for (let blade = 0; blade < 3; blade++) {
            const tx = dx + (blade - 1) * 0.16, tz = dz + 0.32
            if (landscapePocket(tx, tz)) tufts.push([tx, terrainHeight(tx, tz), tz, 0.8, 0.85, 0.8, angle])
          }
        }
      })
    }
    instances(tile, "world-tree-trunks", trunkGeometry, trunkMaterial, trunks)
    instances(tile, "world-tree-crowns", crownGeometry, crownMaterial, crowns)
    instances(tile, "world-shrubs", crownGeometry, shrubMaterial, shrubs)
    instances(tile, "world-stones", stoneGeometry, stoneMaterial, stones)
    instances(tile, "world-wildflowers", crownGeometry, petalMaterial, flowers)
    instances(tile, "world-grass-tufts", bladeGeometry, grassMaterial, tufts)
    if (cz === 0) {
      const posts = [], caps = []
      for (let x = x0 + 8; x < x0 + CHUNK_SIZE; x += 16) for (const side of [-1, 1]) {
        if (Math.abs(x + 29) < 5) continue
        const z = roadZ(x) + side * 4.7
        posts.push([x, 0.26, z, 0.10, 0.65, 0.10])
        caps.push([x, 0.54, z, 0.115, 0.13, 0.115])
      }
      instances(tile, "world-road-posts", postGeometry, markingMaterial, posts)
      instances(tile, "world-road-reflectors", postGeometry, shoulderMaterial, caps)
    }
    group.add(tile)
    return tile
  }
  function remove(key, tile) {
    tile.traverse(node => { if (node.isInstancedMesh) node.dispose(); else node.geometry?.dispose() })
    group.remove(tile); chunks.delete(key)
  }
  let center = ""
  return {
    group,
    update(x, z) {
      const next = `${Math.floor(x / CHUNK_SIZE)},${Math.floor(z / CHUNK_SIZE)}`
      if (center === next) return
      center = next
      const wanted = new Set(chunkKeys(x, z).map(([cx, cz]) => `${cx},${cz}`))
      for (const [key, tile] of chunks) if (!wanted.has(key)) remove(key, tile)
      for (const key of wanted) if (!chunks.has(key)) { const [cx, cz] = key.split(",").map(Number); chunks.set(key, build(cx, cz)) }
    },
    dispose() {
      for (const [key, tile] of chunks) remove(key, tile)
      sharedResources.forEach(resource => resource.dispose())
    }
  }
}
