// Small, discoverable objects use the same furniture scale as the Puckies (CYRA-1283).
export function createOfficeDetails(THREE) {
  const group = new THREE.Group()
  group.name = "office-details"
  const discoveries = [], animations = new Map(), active = new Map(), animatedRoots = new Set()
  const geometries = new Set(), materials = new Set()
  const remember = geometry => { geometries.add(geometry); return geometry }
  const cube = remember(new THREE.BoxGeometry(1, 1, 1))
  const sphere = remember(new THREE.SphereGeometry(1, 12, 8))
  const cylinder = remember(new THREE.CylinderGeometry(1, 1, 1, 16))
  const cone = remember(new THREE.ConeGeometry(1, 1, 12))
  const material = color => { const mat = new THREE.MeshStandardMaterial({ color, roughness: 0.8 }); materials.add(mat); return mat }
  const ink = material("#3e3949"), cream = material("#fff1d6"), sage = material("#8bb194")
  const lilac = material("#b7a1cf"), coral = material("#d99485"), gold = material("#e5c47c")
  const blue = material("#8eb9c7"), wood = material("#bd9669"), paper = material("#fff8e9")
  const colors = [sage, lilac, coral, blue, gold]
  function mesh(geometry, mat, parent, x, y, z, sx, sy, sz) {
    const item = new THREE.Mesh(geometry, mat)
    item.position.set(x, y, z); item.scale.set(sx, sy, sz)
    item.castShadow = item.receiveShadow = true
    parent.add(item)
    return item
  }
  const box = (parent, mat, x, y, z, w, h, d) => mesh(cube, mat, parent, x, y, z, w, h, d)
  const oval = (parent, mat, x, y, z, w, h, d) => mesh(sphere, mat, parent, x, y, z, w, h, d)
  const disk = (parent, mat, x, y, z, r, h) => mesh(cylinder, mat, parent, x, y, z, r, h, r)
  function at(x, y, z, parent = group) { const item = new THREE.Group(); item.position.set(x, y, z); parent.add(item); return item }
  function secret(id, x, y, z, pose) {
    const root = at(x, y, z)
    root.name = `secret-${id}`; root.userData.discoveryId = id
    discoveries.push({ id, group: root, position: root.position.clone() })
    animatedRoots.add(root)
    animations.set(id, pose)
    return root
  }
  function notebook(parent, x, y, z, mat, angle = 0) {
    const book = at(x, y, z, parent)
    book.rotation.y = angle
    box(book, mat, 0, 0, 0, 0.30, 0.045, 0.39)
    box(book, paper, 0.015, 0.025, 0, 0.26, 0.01, 0.34)
    box(book, gold, -0.06, 0.033, 0, 0.018, 0.006, 0.35)
  }
  function envelope(parent, x, y, z, angle = 0) {
    const letter = at(x, y, z, parent); letter.rotation.y = angle
    box(letter, cream, 0, 0, 0, 0.34, 0.018, 0.22)
    box(letter, coral, 0.11, 0.013, -0.06, 0.065, 0.005, 0.055)
    box(letter, wood, -0.04, 0.013, 0.02, 0.14, 0.004, 0.012)
  }

  // Mail, stationery, headphones and photographs make individual desks feel inhabited.
  const mail = at(-16.9, 1.07, -6.72)
  box(mail, wood, 0, 0.035, 0, 0.6, 0.06, 0.4)
  for (let i = 0; i < 3; i++) envelope(mail, 0, 0.08 + i * 0.025, 0, i * 0.10)
  ;[[-21.3, 0.25, -7.6], [-20.8, 0.18, -7.5]].forEach(([x, y, z], i) => {
    box(group, wood, x, y, z, 0.5, y * 2, 0.45)
    box(group, cream, x, y * 2 + 0.004, z, 0.06, 0.008, 0.46)
    box(group, paper, x, y * 1.3, z + 0.23, 0.16, 0.08, 0.008)
  })
  ;[[-7, -8.1], [-2.5, -6.1], [2, -8.1], [-7, -3.1], [-2.5, -3.1], [2, -3.1]].forEach(([x, z], i) => {
    notebook(group, x - 0.55, 0.9, z + 0.05, colors[i % colors.length], i * 0.12)
    const photograph = at(x + 0.55, 0.92, z - 0.18)
    photograph.rotation.x = -0.15
    box(photograph, wood, 0, 0.11, 0, 0.20, 0.23, 0.035)
    box(photograph, cream, 0, 0.11, 0.023, 0.16, 0.18, 0.009)
    oval(photograph, colors[(i + 2) % colors.length], 0, 0.13, 0.034, 0.045, 0.06, 0.012)
    if (i % 2 === 0) {
      const headphones = at(x - 0.8, 0.98, z + 0.25)
      const arc = new THREE.Mesh(remember(new THREE.TorusGeometry(0.10, 0.018, 6, 12, Math.PI)), ink)
      headphones.add(arc)
      for (const side of [-1, 1]) oval(headphones, ink, side * 0.1, 0, 0, 0.04, 0.055, 0.035)
    }
  })

  // A reception lucky cat waves a paw, never the whole sculpture.
  let catPaw
  const cat = secret("lucky_cat", -18.65, 1.06, -6.7, (phase, moving, revealed) => {
    catPaw.rotation.z = revealed ? -0.7 + (moving ? Math.sin(phase * 12) * 0.35 : 0) : -0.15
  })
  disk(cat, lilac, 0, 0.025, 0, 0.23, 0.05)
  oval(cat, cream, 0, 0.20, 0, 0.17, 0.20, 0.14)
  oval(cat, cream, 0, 0.42, 0.015, 0.19, 0.16, 0.15)
  for (const side of [-1, 1]) {
    mesh(cone, cream, cat, side * 0.13, 0.57, 0, 0.07, 0.14, 0.07)
    oval(cat, ink, side * 0.065, 0.44, 0.15, 0.018, 0.023, 0.012)
  }
  oval(cat, coral, 0, 0.39, 0.16, 0.025, 0.018, 0.015)
  oval(cat, gold, 0, 0.19, 0.14, 0.09, 0.12, 0.025)
  catPaw = at(0.15, 0.31, 0, cat)
  oval(catPaw, cream, 0.02, 0.08, 0, 0.06, 0.13, 0.065)

  // Meeting supplies, with one folded paper plane waiting for a short flight.
  notebook(group, 17.4, 0.9, -7.55, coral, 0.2)
  const plane = secret("paper_plane", 14.3, 0.94, -7.0, (phase, moving, revealed) => {
    const lift = moving ? Math.sin(phase * Math.PI) : revealed ? 0.25 : 0
    plane.position.set(14.3 + (moving ? Math.sin(phase * Math.PI * 2) * 0.75 : 0), 0.94 + lift * 0.65, -7.0 + lift * 0.5)
    plane.rotation.z = moving ? Math.sin(phase * Math.PI * 2) * 0.22 : 0
  })
  const wing = remember(new THREE.BufferGeometry())
  wing.setAttribute("position", new THREE.Float32BufferAttribute([-0.33, 0, -0.24, 0, 0.08, 0.43, 0, -0.035, -0.12, 0, -0.035, -0.12, 0, 0.08, 0.43, 0.33, 0, -0.24], 3))
  wing.computeVertexNormals()
  const planeMaterial = material("#fff3d7"); planeMaterial.side = THREE.DoubleSide
  plane.add(new THREE.Mesh(wing, planeMaterial))
  box(plane, coral, 0, -0.025, -0.10, 0.035, 0.02, 0.20)

  // A travel-sized board game and cushions live beside the lounge's existing books.
  const board = at(-5.25, 0.56, 7.25)
  box(board, wood, 0, 0, 0, 0.55, 0.025, 0.42)
  for (let x = 0; x < 4; x++) for (let z = 0; z < 3; z++) box(board, (x + z) % 2 ? sage : cream, -0.19 + x * 0.125, 0.016, -0.13 + z * 0.125, 0.12, 0.007, 0.12)
  ;[[-0.18, -0.13, coral], [0.07, 0.12, lilac], [0.19, 0, gold]].forEach(([x, z, mat]) => disk(board, mat, x, 0.04, z, 0.04, 0.045))
  const arcade = secret("tiny_arcade", 3.5, 0.06, 9.2, (phase, moving, revealed) => {
    invader.position.x = revealed ? (moving ? Math.sin(phase * Math.PI * 4) * 0.12 : 0.08) : 0
    screenMat.emissiveIntensity = revealed ? 0.7 : 0.12
  })
  box(arcade, lilac, 0, 0.52, 0, 0.68, 1.04, 0.58)
  box(arcade, ink, 0, 0.83, 0.30, 0.52, 0.38, 0.035)
  const screenMat = material("#8eb9c7"); screenMat.emissive.set("#6aafa8"); screenMat.emissiveIntensity = 0.12
  box(arcade, screenMat, 0, 0.84, 0.324, 0.44, 0.28, 0.016)
  box(arcade, cream, 0, 1.12, 0.08, 0.72, 0.12, 0.58)
  box(arcade, ink, 0, 0.59, 0.36, 0.61, 0.08, 0.24)
  disk(arcade, coral, 0.18, 0.65, 0.39, 0.055, 0.035)
  disk(arcade, ink, -0.16, 0.69, 0.39, 0.025, 0.14)
  oval(arcade, gold, -0.16, 0.77, 0.39, 0.055, 0.055, 0.055)
  const invader = at(0, 0.84, 0.34, arcade)
  ;[[-1, 1], [1, 1], [-2, 0], [-1, 0], [0, 0], [1, 0], [2, 0], [-2, -1], [2, -1]].forEach(([x, y]) => box(invader, cream, x * 0.034, y * 0.034, 0, 0.03, 0.03, 0.009))

  // Cafe pastries and a biscuit tin containing a small golden star.
  const pastry = at(20.8, 1.1, 15.75)
  disk(pastry, cream, 0, 0, 0, 0.26, 0.025)
  for (let i = 0; i < 3; i++) { const roll = oval(pastry, gold, (i - 1) * 0.14, 0.07, 0, 0.10, 0.06, 0.075); roll.rotation.y = i * 0.3 }
  let tinLid, star
  const tin = secret("cookie_tin", 18.2, 1.08, 15.55, (phase, moving, revealed) => {
    const opening = revealed ? moving ? Math.sin(phase * Math.PI) : 0.8 : 0
    tinLid.position.y = 0.18 + opening * 0.32
    tinLid.rotation.z = opening * 0.5
    star.position.y = 0.19 + opening * 0.15
    star.visible = revealed
  })
  disk(tin, coral, 0, 0.08, 0, 0.23, 0.16)
  disk(tin, ink, 0, 0.165, 0, 0.20, 0.01)
  tinLid = at(0, 0.18, 0, tin)
  disk(tinLid, cream, 0, 0, 0, 0.24, 0.035)
  disk(tinLid, coral, 0, 0.025, 0, 0.06, 0.04)
  star = at(0, 0.19, 0, tin)
  for (let i = 0; i < 5; i++) {
    const petal = oval(star, gold, Math.sin(i * Math.PI * 0.4) * 0.055, 0, Math.cos(i * Math.PI * 0.4) * 0.055, 0.055, 0.025, 0.10)
    petal.rotation.y = i * Math.PI * 0.4
  }

  // A shy snail lives beside a miniature door and mushroom circle in the park.
  let feelers
  const snail = secret("garden_snail", -16.8, 0.07, 19.5, (phase, moving, revealed) => {
    snail.position.x = -16.8 + (moving ? Math.sin(phase * Math.PI) * 0.32 : 0)
    feelers.rotation.x = revealed ? -0.2 + (moving ? Math.sin(phase * Math.PI * 4) * 0.12 : 0) : 0.3
  })
  oval(snail, sage, 0, 0.08, 0, 0.30, 0.09, 0.13)
  oval(snail, coral, -0.07, 0.24, 0, 0.20, 0.20, 0.14)
  const spiral = new THREE.Mesh(remember(new THREE.TorusGeometry(0.10, 0.018, 6, 16, Math.PI * 1.7)), cream)
  spiral.position.set(-0.07, 0.24, 0.14); snail.add(spiral)
  feelers = at(0.23, 0.13, 0, snail)
  for (const side of [-1, 1]) {
    box(feelers, sage, 0, 0.10, side * 0.075, 0.018, 0.20, 0.018)
    oval(feelers, ink, 0, 0.21, side * 0.075, 0.022, 0.022, 0.022)
  }
  const fairyDoor = at(-20.5, 0.07, 22.18)
  box(fairyDoor, wood, 0, 0.26, 0, 0.36, 0.52, 0.045)
  for (const side of [-1, 1]) box(fairyDoor, cream, side * 0.21, 0.27, 0.02, 0.045, 0.57, 0.06)
  oval(fairyDoor, gold, 0.11, 0.23, 0.035, 0.025, 0.025, 0.025)
  ;[[-0.5, 0.18], [0.42, 0.22], [0.65, -0.13]].forEach(([x, z]) => {
    disk(fairyDoor, cream, x, 0.08, z, 0.035, 0.16)
    oval(fairyDoor, coral, x, 0.17, z, 0.12, 0.07, 0.12)
    oval(fairyDoor, cream, x - 0.04, 0.23, z, 0.025, 0.012, 0.025)
  })

  // The server caretaker has a movable head and an old-fashioned winding key.
  let robotHead
  const robot = secret("server_robot", 21.6, 0.06, 6.5, (phase, moving, revealed) => {
    robotHead.rotation.y = revealed ? moving ? Math.sin(phase * Math.PI * 4) * 0.5 : 0.4 : 0
    antennaMat.emissiveIntensity = revealed ? 1.2 : 0
  })
  box(robot, blue, 0, 0.30, 0, 0.35, 0.38, 0.25)
  robotHead = at(0, 0.59, 0, robot)
  box(robotHead, cream, 0, 0, 0, 0.40, 0.27, 0.29)
  const antennaMat = material("#e5c47c"); antennaMat.emissive.set("#e5c47c"); antennaMat.emissiveIntensity = 0
  disk(robotHead, ink, 0, 0.20, 0, 0.015, 0.16)
  oval(robotHead, antennaMat, 0, 0.29, 0, 0.055, 0.055, 0.055)
  for (const side of [-1, 1]) {
    oval(robotHead, ink, side * 0.09, 0.015, 0.15, 0.045, 0.045, 0.02)
    box(robot, ink, side * 0.13, 0.06, 0.04, 0.14, 0.12, 0.21)
    box(robot, gold, side * 0.24, 0.32, 0, 0.09, 0.25, 0.11).rotation.z = side * 0.15
  }
  for (let i = 0; i < 3; i++) box(robot, cream, -0.07 + i * 0.07, 0.32, 0.13, 0.04, 0.07, 0.014)
  box(robot, gold, 0, 0.34, -0.23, 0.24, 0.065, 0.045)
  box(robot, gold, 0, 0.34, -0.18, 0.045, 0.065, 0.17)

  // A loose notebook on the coordination cabinet hides a tiny brass key.
  box(group, wood, 19, 1.56, -3.7, 2, 0.04, 0.4)
  let bookCover, key
  const book = secret("secret_book", 19.6, 1.58, -3.7, (phase, moving, revealed) => {
    bookCover.rotation.z = revealed ? -(moving ? Math.sin(phase * Math.PI) : 0.85) * 1.3 : 0
    key.visible = revealed
  })
  box(book, lilac, 0, 0.04, 0, 0.46, 0.08, 0.40)
  box(book, paper, 0, 0.09, 0, 0.42, 0.025, 0.36)
  bookCover = at(-0.23, 0.11, 0, book)
  box(bookCover, lilac, 0.23, 0, 0, 0.46, 0.025, 0.40)
  key = at(0, 0.12, 0, book)
  disk(key, gold, -0.06, 0, 0, 0.055, 0.025)
  box(key, gold, 0.04, 0, 0, 0.16, 0.025, 0.025)
  box(key, gold, 0.1, 0, 0.03, 0.025, 0.025, 0.06)

  let lastTime = 0, disposed = false
  function update(time, reducedMotion) {
    lastTime = time
    for (const [id, pose] of animations) {
      const started = active.get(id)
      const elapsed = started === undefined ? Infinity : Math.max(0, time - started)
      const revealed = elapsed < 3.2
      pose(Math.min(1, elapsed / 3.2), revealed && !reducedMotion, revealed)
      if (!revealed) active.delete(id)
    }
  }
  update(0, false)
  return {
    group, discoveries, animatedRoots,
    activate(id) { if (!animations.has(id) || disposed) return false; active.set(id, lastTime); return true },
    update,
    dispose() {
      if (disposed) return
      disposed = true
      geometries.forEach(geometry => geometry.dispose())
      materials.forEach(mat => mat.dispose())
      group.removeFromParent()
    }
  }
}
