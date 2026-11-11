// Gallery identities stay independent from selection and activity colours (CYRA-1283).
export function mascotChoice(value) {
  return /^(0[1-9]|1[0-9]|20)$/.test(value) ? value : "01"
}

export function createMascot(THREE, value) {
  const id = mascotChoice(value)
  const group = new THREE.Group(), arms = [], eyes = [], feet = []
  const colors = ["#77bdf4", "#8ec9ac", "#b385ed", "#f6a25b", "#f4da84", "#ef8a9e", "#71cbd0", "#fff0ce", "#91bf88", "#f7c798", "#f6d566", "#ef8f90", "#fff1d6", "#81b9e1", "#f8df86", "#b79ae2", "#96cbb6", "#a4b5ed", "#b78a55", "#f4de85"]
  const material = (color, roughness = 0.88) => new THREE.MeshStandardMaterial({ color, roughness })
  const skin = material(colors[Number(id) - 1]), cream = material("#fff0d3")
  const purple = material("#b299dd"), coral = material("#f28a9b"), green = material("#76b396")
  const ink = material("#302520", 0.15), white = material("#ffffff", 0.2)
  const yellow = material("#ffe184"), brown = material("#775238")
  const sphere = new THREE.SphereGeometry(1, 24, 16)
  function oval(mat, x, y, z, sx, sy, sz, parent = group) {
    const mesh = new THREE.Mesh(sphere, mat)
    mesh.position.set(x, y, z)
    mesh.scale.set(sx, sy, sz)
    mesh.castShadow = mesh.receiveShadow = true
    parent.add(mesh)
    return mesh
  }
  function body() { oval(skin, 0, 0.72, 0, 0.53, 0.66, 0.38) }
  function leaf(x, y, angle, mat = green) {
    const mesh = oval(mat, x, y, 0, 0.13, 0.32, 0.07)
    mesh.rotation.z = angle
  }
  function scarf() {
    oval(coral, 0, 0.65, 0.02, 0.59, 0.10, 0.41)
    oval(coral, 0.34, 0.48, 0.39, 0.13, 0.26, 0.08).rotation.z = 0.15
  }
  function bow() {
    oval(yellow, -0.12, 0.58, 0.40, 0.15, 0.12, 0.06).rotation.z = -0.3
    oval(yellow, 0.12, 0.58, 0.40, 0.15, 0.12, 0.06).rotation.z = 0.3
    oval(yellow, 0, 0.58, 0.45, 0.075, 0.075, 0.05)
  }
  function beanie() {
    oval(purple, 0.08, 1.32, 0, 0.43, 0.34, 0.35).rotation.z = -0.2
    oval(purple, 0, 1.19, 0.02, 0.48, 0.10, 0.37)
    oval(purple, 0.24, 1.64, 0, 0.17, 0.17, 0.16)
  }
  function belly() { oval(cream, 0, 0.53, 0.34, 0.30, 0.32, 0.075) }
  function antennae() {
    for (const side of [-1, 1]) {
      oval(green, side * 0.27, 1.37, 0, 0.035, 0.22, 0.035).rotation.z = -side * 0.4
      oval(green, side * 0.35, 1.55, 0, 0.10, 0.10, 0.10)
    }
  }
  function star() {
    const shape = new THREE.Shape(), points = []
    for (let i = 0; i < 10; i++) {
      const angle = Math.PI / 2 + i * Math.PI / 5, radius = i % 2 ? 0.43 : 0.70
      points.push(new THREE.Vector2(Math.cos(angle) * radius, 0.78 + Math.sin(angle) * radius))
    }
    const start = points[0].clone().lerp(points[9], 0.5)
    shape.moveTo(start.x, start.y)
    points.forEach((point, i) => {
      const end = point.clone().lerp(points[(i + 1) % 10], 0.5)
      shape.quadraticCurveTo(point.x, point.y, end.x, end.y)
    })
    const geometry = new THREE.ExtrudeGeometry(shape, { depth: 0.28, bevelEnabled: true, bevelSegments: 5, steps: 1, bevelSize: 0.13, bevelThickness: 0.19, curveSegments: 8 })
    const mesh = new THREE.Mesh(geometry, skin)
    mesh.position.z = -0.14
    mesh.castShadow = mesh.receiveShadow = true
    group.add(mesh)
    scarf()
  }

  switch (id) {
    case "01":
      oval(skin, 0, 0.67, 0, 0.51, 0.55, 0.36)
      oval(skin, 0, 1.13, 0, 0.37, 0.40, 0.34)
      oval(skin, -0.40, 0.89, 0, 0.29, 0.32, 0.30)
      oval(skin, 0.40, 0.89, 0, 0.29, 0.32, 0.30)
      bow(); break
    case "02":
      body(); belly(); leaf(-0.16, 1.48, 0.65); leaf(0.16, 1.48, -0.65); break
    case "03": star(); break
    case "08":
      oval(cream, 0, 0.57, 0, 0.42, 0.44, 0.34)
      oval(purple, 0, 1.13, -0.02, 0.74, 0.48, 0.53)
      for (const [x, y, z, scale] of [[0, 1.48, 0.29, 0.15], [-0.46, 1.23, 0.37, 0.13], [0.43, 1.24, 0.38, 0.14], [0.28, 1.48, -0.25, 0.12]]) {
        oval(cream, x, y, z, scale, scale, 0.045).rotation.x = -0.4
      }
      break
    case "13":
      body(); beanie()
      for (const x of [-0.35, 0, 0.35]) oval(skin, x, 0.25, 0, 0.23, 0.22, 0.32)
      break
    case "04": body(); oval(green, 0, 0.52, 0.35, 0.30, 0.23, 0.06); break
    case "05": body(); leaf(0.05, 1.30, -0.55, yellow); break
    case "06":
      body(); oval(skin, -0.28, 1.17, 0, 0.34, 0.34, 0.33); oval(skin, 0.28, 1.17, 0, 0.34, 0.34, 0.33); scarf(); break
    case "07": body(); oval(skin, 0, 1.43, 0, 0.13, 0.18, 0.12); belly(); break
    case "09":
      body()
      for (const side of [-1, 1]) oval(skin, side * 0.57, 0.76, 0, 0.16, 0.29, 0.16)
      for (let i = 0; i < 5; i++) oval(coral, 0.27 + Math.cos(i * 1.26) * 0.1, 1.35 + Math.sin(i * 1.26) * 0.1, 0.12, 0.08, 0.08, 0.045)
      break
    case "10": body(); leaf(-0.1, 1.38, 1.1, green); break
    case "11": case "20":
      for (let i = 0; i < 10; i++) {
        const angle = i * Math.PI / 5
        const petal = oval(id === "20" ? cream : skin, Math.sin(angle) * 0.54, 0.85 + Math.cos(angle) * 0.54, -0.08, 0.15, 0.23, 0.13)
        petal.rotation.z = -angle
      }
      oval(skin, 0, 0.85, 0, 0.51, 0.51, 0.34); bow(); break
    case "12":
      body(); leaf(-0.14, 1.30, 1.1); leaf(0.14, 1.30, -1.1)
      for (const x of [-0.28, 0, 0.28]) for (const y of [0.45, 0.70]) oval(cream, x, y, 0.36, 0.025, 0.045, 0.015)
      break
    case "14": body(); belly(); oval(skin, 0.50, 0.70, -0.14, 0.26, 0.15, 0.16).rotation.z = 0.5; break
    case "15":
      body(); antennae()
      for (const y of [0.35, 0.57]) oval(brown, 0, y, 0.02, 0.50, 0.085, 0.37)
      for (const side of [-1, 1]) oval(cream, side * 0.54, 0.92, -0.20, 0.22, 0.33, 0.08)
      break
    case "16": body(); belly(); antennae(); break
    case "17": body(); antennae(); oval(material("#e5ad85"), 0.33, 0.65, -0.25, 0.43, 0.48, 0.30); belly(); break
    case "18": body(); belly(); oval(cream, 0, 0.98, 0.25, 0.37, 0.32, 0.13); scarf(); break
    case "19": body(); belly(); oval(brown, 0, 1.25, 0, 0.56, 0.27, 0.40); oval(brown, 0, 1.53, 0, 0.065, 0.14, 0.06); break
  }

  const faceY = id === "08" ? 0.61 : 0.98
  for (const side of [-1, 1]) {
    const arm = new THREE.Group()
    arm.position.set(side * 0.48, 0.64, 0)
    oval(skin, side * 0.035, -0.08, 0, 0.14, 0.23, 0.16, arm).rotation.z = side * 0.3
    group.add(arm); arms.push(arm)
    feet.push(oval(skin, side * 0.24, 0.13, 0.04, 0.20, 0.14, 0.24))
    const eye = new THREE.Group()
    eye.position.set(side * 0.17, faceY, 0.35)
    oval(ink, 0, 0, 0, 0.065, 0.085, 0.045, eye)
    oval(white, -0.017, 0.025, 0.04, 0.018, 0.024, 0.012, eye)
    group.add(eye); eyes.push(eye)
  }
  const smile = new THREE.Mesh(new THREE.TorusGeometry(0.06, 0.014, 6, 14, Math.PI), ink)
  smile.rotation.z = Math.PI
  smile.position.set(0, faceY - 0.10, 0.385)
  group.add(smile)
  // Keep the characters at furniture scale: desktops sit around the middle of their bodies.
  group.scale.setScalar(0.85)
  return { group, arms, eyes, feet }
}

export function animateMascot(mascot, { time, phase, walking, working, greeting, reducedMotion, sitting = false }) {
  mascot.feet.forEach(foot => {
    foot.position.set(foot.position.x, sitting ? 0.02 : 0.13, sitting ? 0.30 : 0.04)
    foot.rotation.x = sitting ? -0.35 : 0
  })
  const blinkPhase = (time + phase * 2.3) % 5.7
  const blink = !reducedMotion && blinkPhase < 0.18 ? 1 - Math.sin(blinkPhase / 0.18 * Math.PI) * 0.94 : 1
  mascot.eyes.forEach(eye => { eye.scale.y = blink })
  mascot.group.rotation.z = reducedMotion ? 0 : Math.sin(time * (walking ? 8 : 1.4) + phase) * (walking ? 0.035 : 0.012)
  mascot.group.rotation.x = !reducedMotion && working ? 0.05 + Math.sin(time * 0.8 + phase) * 0.025 : 0
  mascot.arms.forEach((arm, index) => {
    arm.rotation.z = 0
    if (reducedMotion) { arm.rotation.x = 0; return }
    if (greeting && index === 1) {
      arm.rotation.x = -0.25
      arm.rotation.z = 2.1 + Math.sin(time * 7) * 0.25
    } else if (working) arm.rotation.x = -0.7 + Math.sin(time * 5 + phase + index * Math.PI) * 0.12
    else arm.rotation.x = Math.sin(time * (walking ? 8 : 1.3) + phase + index * Math.PI) * (walking ? 0.48 : 0.045)
  })
}
