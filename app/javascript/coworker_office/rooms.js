// Additional wings are a visual reflection of server-authorized Puck configuration.
export const ROOM_CENTERS = { archive: [-16, -21], observatory: [0, -21], workshop: [16, -21] }
export function createSpecialRooms(THREE, active = [], finishes = {}) {
  const group = new THREE.Group(), centers = new Map()
  group.name = "specialist-rooms"
  const cube = new THREE.BoxGeometry(1, 1, 1), sphere = new THREE.SphereGeometry(1, 12, 8)
  const cylinder = new THREE.CylinderGeometry(1, 1, 1, 12)
  const mat = color => new THREE.MeshStandardMaterial({ color, roughness: 0.85 })
  const wall = finishes.wall || mat("#f0e7d8"), wood = finishes.wood || mat("#c59f71"), ink = mat("#454354"), metal = mat("#9da6aa"), paper = mat("#f6edce")
  const sage = mat("#8aa78d"), rose = mat("#c8908d"), blue = mat("#8eafc5"), amber = mat("#d4ad68")
  const path = finishes.path || paper
  const palette = [sage, rose, blue, amber, paper]
  function mesh(parent, geometry, material, x, y, z, sx, sy, sz) {
    const object = new THREE.Mesh(geometry, material)
    object.position.set(x, y, z); object.scale.set(sx, sy, sz)
    object.castShadow = object.receiveShadow = true
    parent.add(object); return object
  }
  const box = (p, m, x, y, z, w, h, d) => mesh(p, cube, m, x, y, z, w, h, d)
  const ball = (p, m, x, y, z, w, h, d) => mesh(p, sphere, m, x, y, z, w, h, d)
  const tube = (p, m, x, y, z, r, h) => mesh(p, cylinder, m, x, y, z, r, h, r)
  function desk(p, x, z) {
    box(p, wood, x, 0.78, z, 2.4, 0.12, 1.2)
    for (const dx of [-1, 1]) for (const dz of [-0.45, 0.45]) box(p, metal, x + dx, 0.39, z + dz, 0.07, 0.78, 0.07)
    box(p, ink, x, 0.48, z + 1, 0.65, 0.12, 0.65)
    box(p, sage, x, 0.85, z + 1.27, 0.65, 0.65, 0.12)
    tube(p, metal, x, 0.24, z + 1, 0.07, 0.48)
  }
  function bookcase(p, x, z, seed) {
    box(p, wood, x, 1, z, 2.8, 2, 0.58)
    box(p, ink, x, 1.08, z + 0.305, 2.58, 1.7, 0.035)
    for (let level = 0; level < 3; level++) {
      const y = 0.35 + level * 0.55
      box(p, wood, x, y, z + 0.07, 2.7, 0.065, 0.66)
      for (let i = 0; i < 13; i++) {
        const h = 0.27 + ((i + seed + level) % 3) * 0.07
        const bx = x - 1.15 + i * 0.19
        box(p, palette[(i + seed + level) % 5], bx, y + h / 2 + 0.04, z + 0.32, 0.14, h, 0.23)
        box(p, paper, bx, y + 0.12, z + 0.441, 0.09, 0.025, 0.012)
      }
    }
  }
  function planter(p, x, z) {
    tube(p, paper, x, 0.25, z, 0.3, 0.5)
    for (let i = 0; i < 5; i++) ball(p, sage, x + Math.cos(i * 1.3) * 0.2, 0.7 + i * 0.09, z + Math.sin(i * 1.3) * 0.2, 0.17, 0.38, 0.13)
  }
  for (const id of [...new Set(active)].filter(id => Object.hasOwn(ROOM_CENTERS, id))) {
    const [x, z] = ROOM_CENTERS[id], room = new THREE.Group()
    room.name = `room-${id}`; room.position.set(x, 0, z); group.add(room); centers.set(id, room.position.clone())
    box(room, wall, 0, 0.03, 0, 12.5, 0.1, 9)
    const floor = id === "archive" ? wood : id === "observatory" ? blue : sage
    for (let row = 0; row < 12; row++) for (let col = 0; col < 6; col++) box(room, floor, -5.2 + col * 2.08, 0.09, -4.1 + row * 0.73, 2.04, 0.02, 0.7)
    box(room, wall, 0, 0.7, -4.5, 12.5, 1.3, 0.22)
    for (const side of [-1, 1]) {
      box(room, wall, side * 6.25, 0.7, 0, 0.22, 1.3, 9)
      box(room, wall, side * 3.75, 0.7, 4.5, 5, 1.3, 0.22)
      box(room, wood, side * 6.25, 1.38, 0, 0.27, 0.07, 9)
      planter(room, side * 5.2, 3.4)
    }
    box(room, wood, 0, 1.38, -4.5, 12.5, 0.07, 0.27)
    // A shared north walkway joins every wing to the existing east corridor.
    box(room, path, 0, 0.015, 6, 12.5, 0.04, 3)
    // Personal scale details make each wing a working room rather than an empty stage.
    const clock = tube(room, paper, 5.1, 1.05, -4.32, 0.29, 0.055)
    clock.rotation.x = Math.PI / 2
    box(room, ink, 5.1, 1.13, -4.28, 0.025, 0.16, 0.025)
    box(room, ink, 5.18, 1.05, -4.28, 0.17, 0.025, 0.025)
    for (let i = 0; i < 3; i++) {
      box(room, wood, -5.1, 0.3 + i * 0.25, 2.9, 0.8, 0.23, 0.7)
      box(room, metal, -5.1, 0.3 + i * 0.25, 3.26, 0.25, 0.035, 0.025)
    }
    if (id === "archive") {
      ;[-4, 0, 4].forEach((x, i) => bookcase(room, x, -3.65, i))
      for (const side of [-1, 1]) {
        const shelves = new THREE.Group(); shelves.position.set(side * 5.5, 0, -0.8); shelves.rotation.y = -side * Math.PI / 2; room.add(shelves)
        bookcase(shelves, 0, 0, 2)
      }
      box(room, sage, 0, 0.12, 1, 7.4, 0.025, 4.6)
      desk(room, -2.2, 0.5); desk(room, 2, 0.5)
      box(room, metal, -0.1, 0.45, -1.8, 0.9, 0.06, 0.6)
      box(room, metal, -0.1, 0.78, -1.8, 0.9, 0.06, 0.6)
      for (const side of [-1, 1]) { tube(room, ink, -0.1 + side * 0.35, 0.18, -1.8, 0.075, 0.12); box(room, metal, -0.1 + side * 0.4, 0.55, -1.8, 0.035, 0.9, 0.5) }
      for (let i = 0; i < 5; i++) box(room, palette[i], -0.4 + i * 0.15, 0.98, -1.8, 0.11, 0.35, 0.37)
      for (const x of [-2.5, 1.6]) {
        box(room, rose, x, 0.87, 0.5, 0.7, 0.055, 0.5)
        box(room, paper, x + 0.12, 0.91, 0.5, 0.5, 0.02, 0.45)
        tube(room, wood, x + 0.9, 1.12, 0.25, 0.035, 0.55)
        ball(room, amber, x + 0.9, 1.4, 0.25, 0.26, 0.14, 0.2)
      }
      tube(room, wood, 4.8, 0.45, 0, 0.08, 0.7); ball(room, blue, 4.8, 1.05, 0, 0.43, 0.43, 0.43)
      ball(room, sage, 4.65, 1.25, 0.31, 0.18, 0.16, 0.1)
      for (const x of [-5.3, -4.6]) box(room, wood, x, 1, -2.6, 0.06, 1.8, 0.06)
      for (let i = 0; i < 6; i++) box(room, wood, -4.95, 0.3 + i * 0.27, -2.6, 0.75, 0.055, 0.07)
    } else if (id === "observatory") {
      box(room, ink, 0, 1.05, -4.29, 5.3, 1.3, 0.09)
      for (let i = 0; i < 20; i++) ball(room, paper, -2.4 + (i * 0.61 % 4.8), 0.6 + (i * 0.37 % 0.9), -4.22, 0.025, 0.025, 0.015)
      for (const x of [-3.6, 0, 3.6]) { box(room, paper, x + 0.55, 0.88, -1.65, 0.35, 0.035, 0.3); tube(room, amber, x - 0.75, 0.94, -1.6, 0.075, 0.16) }
      tube(room, metal, 4.8, 0.54, 1.8, 0.06, 1)
      const dish = ball(room, paper, 4.8, 1.22, 1.8, 0.55, 0.12, 0.55); dish.rotation.z = 0.6
      box(room, rose, 4.8, 1.38, 1.8, 0.04, 0.5, 0.04)
      for (const x of [-3.6, 0, 3.6]) {
        desk(room, x, -1.9)
        box(room, ink, x, 1.25, -2.2, 1.4, 0.8, 0.1)
        box(room, blue, x, 1.25, -2.13, 1.25, 0.63, 0.02)
        for (let i = 0; i < 7; i++) box(room, paper, x - 0.52 + i * 0.17, 1.1 + Math.sin(i * 1.7) * 0.13, -2.11, 0.12, 0.035, 0.02)
      }
      const telescope = new THREE.Group(); telescope.position.set(-3.8, 1.1, 1.6); telescope.rotation.z = -0.4; room.add(telescope)
      const scope = tube(telescope, paper, 0, 0.45, 0, 0.24, 1.25); scope.rotation.x = 0.9
      tube(room, metal, -3.8, 0.55, 1.6, 0.07, 1.1)
      for (const side of [-1, 1]) box(room, metal, -3.8 + side * 0.3, 0.12, 1.6, 0.7, 0.08, 0.08)
      box(room, ink, 2.4, 1.05, 1.1, 2.6, 0.15, 1.5)
      for (let i = 0; i < 5; i++) tube(room, palette[i], 1.5 + i * 0.45, 1.18, 1.15, 0.09, 0.1)
    } else {
      // A compact fabrication corner and component trays distinguish the workshop.
      box(room, wood, -4.5, 0.78, -2.7, 2, 0.16, 1.3)
      for (const dx of [-0.8, 0.8]) box(room, metal, -4.5 + dx, 0.39, -2.7, 0.07, 0.78, 1)
      box(room, ink, -4.5, 0.95, -2.7, 1.2, 0.16, 0.9)
      for (const dx of [-0.55, 0.55]) box(room, metal, -4.5 + dx, 1.36, -2.7, 0.07, 0.8, 0.8)
      box(room, ink, -4.5, 1.78, -2.7, 1.2, 0.12, 0.9)
      box(room, metal, -4.5, 1.6, -2.7, 1.1, 0.05, 0.05)
      box(room, rose, -4.3, 1.48, -2.7, 0.15, 0.25, 0.15)
      ball(room, blue, -4.5, 1.15, -2.7, 0.15, 0.16, 0.15)
      for (let i = 0; i < 3; i++) { box(room, wood, 3.6, 0.42 + i * 0.46, -2.85, 2, 0.06, 1.1); for (let j = 0; j < 4; j++) box(room, palette[(i + j) % 5], 2.9 + j * 0.45, 0.55 + i * 0.46, -2.85, 0.35, 0.2, 0.65) }
      desk(room, -2.6, 0); desk(room, 2.6, 0)
      box(room, wood, 0, 1.4, -4.27, 9.8, 1.4, 0.14)
      for (let i = 0; i < 13; i++) {
        box(room, metal, -4.2 + i * 0.7, 1.5, -4.14, 0.06, 0.5, 0.08)
        ball(room, ink, -4.2 + i * 0.7, 1.78, -4.14, 0.12, 0.09, 0.06)
      }
      for (const x of [-2.6, 2.6]) {
        box(room, sage, x, 0.95, 0, 0.8, 0.2, 0.5)
        for (let i = 0; i < 6; i++) box(room, amber, x - 0.3 + i * 0.12, 1.08, 0, 0.05, 0.025, 0.3)
        box(room, rose, x + 0.7, 0.95, -0.25, 0.35, 0.2, 0.4)
      }
      for (let i = 0; i < 3; i++) { box(room, blue, 4.9, 0.3 + i * 0.4, 2.2, 1.1, 0.35, 1); box(room, metal, 4.9, 0.3 + i * 0.4, 2.71, 0.3, 0.04, 0.04) }
    }
  }
  if (centers.size) {
    box(group, path, 0, 0.015, -14.5, 45, 0.04, 2)
    box(group, path, 7.25, 0.015, -12, 2, 0.04, 5)
  }
  return { group, centers }
}
