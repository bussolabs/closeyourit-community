import { createSpecialRooms } from "coworker_office/rooms"
import { createOfficeDetails } from "coworker_office/details"
import { createWorld } from "coworker_office/world"
import { daylightAt } from "coworker_office/daylight"
import { createMascot, mascotChoice, animateMascot } from "coworker_office/mascots"
import { createGardenLife, createUmbrella } from "coworker_office/garden"
import { createAtmosphere } from "coworker_office/atmosphere"
import { batchStaticMeshes } from "coworker_office/batching"

// Coworkers office (CYRA-1283): rooms joined by corridors, a park and a cafeteria outside, one figure
// per Puck. Busy Puckies stay at a desk; the free ones walk out and back, as decoration only.

// Canvas colours cannot be Tailwind classes: these follow the stone/zinc/indigo of DESIGN.md.
const PALETTE = {
  light: { scene: "#eee3d8", ground: "#e8ddcc", floor: "#fff8ec", wall: "#fff5e5", wood: "#e4bc86", fabric: "#baa4d8", plant: "#91ac70",
           rack: "#3a3744", felt: "#4f8f6f", metal: "#b9b5c2", rug: "#cfc8e6", lamp: "#ffd98a", path: "#e9dfca", grass: "#b7cc91",
           water: "#9cc7e0", accent: "#4f46e5", idle: "#9a94a8", ink: "#18181b", muted: "#6b7280", light: 1 },
  dark: { scene: "#15131b", ground: "#343039", floor: "#686071", wall: "#92859e", wood: "#b08b65", fabric: "#9986ba", plant: "#71975e",
          rack: "#24212d", felt: "#55866c", metal: "#9a93aa", rug: "#605475", lamp: "#ffd98a", path: "#5f5666", grass: "#53634b",
          water: "#2f5068", accent: "#818cf8", idle: "#8f899c", ink: "#f4f4f5", muted: "#a1a1aa", light: 0.75 }
}
// Room colours retain their own identity in both themes.
const FLOOR_COLORS = {
  reception: ["#f3d6b4", "#8e725f"], work: ["#e6d6b8", "#817562"],
  meeting: ["#c7d8c2", "#607664"], lead: ["#d3c9df", "#786985"],
  kitchen: ["#e8c0aa", "#956e60"], lounge: ["#d9c3e2", "#806b8d"],
  restrooms: ["#c2dde0", "#587e87"], server: ["#bbc9d8", "#5b6b80"]
}
const TINTED = ["ground", "floor", "wall", "wood", "fabric", "plant", "rack", "felt", "metal", "rug", "path", "grass", "water", "accent"]

// Rooms in plan units; dx/dz push each one apart (world units) to open the corridors between them.
const ROOMS = [
  { key: "reception", x: 10, y: 10, w: 190, h: 120, door: "e", dx: -3, dz: -1.5 },
  { key: "work", x: 210, y: 10, w: 300, h: 200, door: "s", dx: 0, dz: -1.5 },
  { key: "meeting", x: 520, y: 10, w: 270, h: 110, door: "w", dx: 3, dz: -1.5 },
  { key: "lead", x: 520, y: 130, w: 270, h: 80, door: "w", dx: 3, dz: -1.5 },
  { key: "kitchen", x: 10, y: 140, w: 190, h: 130, door: "e", dx: -3, dz: 0 },
  { key: "lounge", x: 210, y: 220, w: 300, h: 130, door: "n", dx: 0, dz: 1.5 },
  { key: "restrooms", x: 520, y: 220, w: 130, h: 130, door: "n", dx: 3, dz: 1.5 },
  { key: "server", x: 660, y: 220, w: 130, h: 130, door: "n", dx: 3, dz: 1.5 }
]

// Where a Puck stands, and the way from there to a corridor crossing ("west" or "east" hub).
const HUBS = { west: [-2, 1.75], east: [7.25, 1.75] }
const SEATS = [
  { at: [-7, -7], out: [[-4.75, -7], [-4.75, -0.6], [-2, -0.6]], hub: "west" },
  { at: [-2.5, -5], out: [[-4.75, -5], [-4.75, -0.6], [-2, -0.6]], hub: "west" },
  { at: [2, -7], out: [[-0.25, -7], [-0.25, -0.6], [-2, -0.6]], hub: "west" },
  { at: [-7, -2], out: [[-7, -0.6], [-2, -0.6]], hub: "west" },
  { at: [-2.5, -2], out: [[-2.5, -0.6], [-2, -0.6]], hub: "west" },
  { at: [2, -2], out: [[2, -0.6], [-2, -0.6]], hub: "west" },
  { at: [15.5, -1.75], out: [[7.25, -1.75]], hub: "east" },
  { at: [19.5, 7.5], out: [[19.25, 4.4], [19.25, 1.75]], hub: "east" },
  ...[12, 13.4, 14.8, 16.2, 17.6, 19].map((x) => ({ at: [x, -5], out: [[10.2, -5], [10.2, -7.25], [7.25, -7.25]], hub: "east" })),
  ...[-8, -6.7, -5.4, -4.1, 0.2, 1.5, 2.8, 4.1].map((x) => ({ at: [x, 4.6], out: [[-2, 4.6]], hub: "west" }))
]
const BREAKS = [
  { west: [[-11.25, 1.75], [-11.25, 17.5]], east: [[7.25, 11.4], [-11.25, 11.4], [-11.25, 17.5]], row: 17.5, spots: [-14, -4.5, -9, -6.5] },
  { west: [[7.25, 1.75], [7.25, 11.4], [12, 11.4], [12, 16.4]], east: [[7.25, 11.4], [12, 11.4], [12, 16.4]], row: 16.4, spots: [17, 15.5, 18.5, 14] }
]
const SCALE = 20, OFFSET_X = 20, OFFSET_Z = 9, WALL_H = 1.2, WALL_T = 0.24, DOOR = 2.3
const SPEED = 2.4, REST_HOME = 5, REST_AWAY = 9

export async function createOffice({ stage, puckies, places, rooms = [], onSelect, onDiscover = () => {}, onFollowChange = () => {} }) {
  const THREE = await import("three")
  const { OrbitControls } = await import("three/examples/jsm/controls/OrbitControls.js")
  const motionPreference = window.matchMedia("(prefers-reduced-motion: reduce)")
  let reducedMotion = motionPreference.matches
  const motionChanged = (event) => { reducedMotion = event.matches }
  motionPreference.addEventListener("change", motionChanged)
  const palette = () => PALETTE[document.documentElement.classList.contains("dark") ? "dark" : "light"]

  const toWorld = (px, py) => [px / SCALE - OFFSET_X, py / SCALE - OFFSET_Z]
  const bounds = (room) => {
    const [x1, z1] = toWorld(room.x, room.y)
    const [x2, z2] = toWorld(room.x + room.w, room.y + room.h)
    return [x1 + room.dx, z1 + room.dz, x2 + room.dx, z2 + room.dz]
  }
  // Furniture is written in the compact plan: a point moves along with the room it sits in.
  const shifted = (object) => {
    const room = ROOMS.find((candidate) => {
      const [x1, z1] = toWorld(candidate.x, candidate.y)
      const [x2, z2] = toWorld(candidate.x + candidate.w, candidate.y + candidate.h)
      return object.position.x >= x1 && object.position.x <= x2 && object.position.z >= z1 && object.position.z <= z2
    })
    if (room) { object.position.x += room.dx; object.position.z += room.dz }
    return object
  }

  const renderer = new THREE.WebGLRenderer({ antialias: true, powerPreference: "high-performance" })
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 1.5))
  renderer.outputColorSpace = THREE.SRGBColorSpace
  renderer.toneMapping = THREE.ACESFilmicToneMapping
  renderer.toneMappingExposure = 1.05
  renderer.shadowMap.enabled = true
  renderer.shadowMap.type = THREE.PCFShadowMap
  renderer.domElement.className = "block h-full w-full touch-none"
  stage.appendChild(renderer.domElement)

  const scene = new THREE.Scene()
  scene.background = new THREE.Color()
  scene.fog = new THREE.Fog(0xe9e5dc, 273, 333)
  const camera = new THREE.OrthographicCamera(-30, 30, 22, -22, 0.1, 500)
  // Orthographic distance preserves scale while keeping foreground hills beyond the near plane.
  const HOME = new THREE.Vector3(0, 176, 209), FOCUS = new THREE.Vector3(0, 0, 5)
  camera.position.copy(HOME)
  const controls = new OrbitControls(camera, renderer.domElement)
  controls.target.copy(FOCUS)
  controls.screenSpacePanning = false
  controls.enableDamping = true
  controls.dampingFactor = 0.065
  controls.maxPolarAngle = Math.PI / 2.3
  controls.minZoom = 0.7
  controls.maxZoom = 4
  controls.update()

  const hemi = new THREE.HemisphereLight(0xfff8eb, 0x7c887c, 1)
  const sun = new THREE.DirectionalLight(0xffedcf, 1)
  const fill = new THREE.DirectionalLight(0xd7e4ff, 0.65)
  sun.position.set(-18, 38, 25)
  sun.target.position.set(0, 0, 5)
  sun.castShadow = true
  const shadowSize = window.innerWidth > 900 ? 2048 : 1024
  sun.shadow.mapSize.set(shadowSize, shadowSize)
  sun.shadow.bias = -0.0003
  sun.shadow.normalBias = 0.025
  sun.shadow.radius = 3
  Object.assign(sun.shadow.camera, { left: -38, right: 38, top: 30, bottom: -30, near: 1, far: 100 })
  fill.position.set(18, 14, -16)
  scene.add(hemi, sun, sun.target, fill)

  const surfaceSettings = {
    wood: { roughness: 0.55 }, metal: { roughness: 0.32, metalness: 0.58 }, rack: { roughness: 0.42, metalness: 0.28 },
    fabric: { roughness: 1 }, rug: { roughness: 1 }, floor: { roughness: 0.82 }, wall: { roughness: 0.9 },
    water: { roughness: 0.16, metalness: 0.08, transparent: true, opacity: 0.88 }
  }
  const mats = Object.fromEntries(TINTED.map((key) => [key, new THREE.MeshStandardMaterial({ roughness: 0.78, metalness: 0, ...surfaceSettings[key] })]))
  Object.assign(mats, { screen: new THREE.MeshBasicMaterial(), eye: new THREE.MeshBasicMaterial(),
                        lamp: new THREE.MeshStandardMaterial({ roughness: 0.45, emissiveIntensity: 0.65 }),
                        ledA: new THREE.MeshBasicMaterial(), ledB: new THREE.MeshBasicMaterial(),
                        glass: new THREE.MeshPhysicalMaterial({ transparent: true, opacity: 0.22, roughness: 0.1, metalness: 0.05, transmission: 0.25, depthWrite: false }) })
  const atmosphere = createAtmosphere(THREE)
  scene.add(atmosphere.water, ...atmosphere.ripples)
  mats.metal.envMap = atmosphere.environment
  mats.metal.envMapIntensity = 0.5
  mats.glass.envMap = atmosphere.environment
  mats.glass.envMapIntensity = 0.45
  const ceramicMaterials = new Map(), windTargets = []
  function ceramic(source) {
    if (!ceramicMaterials.has(source)) {
      const material = source.clone()
      material.roughness = 0.2
      material.metalness = 0
      material.envMap = atmosphere.environment
      material.envMapIntensity = 0.5
      ceramicMaterials.set(source, material)
    }
    return ceramicMaterials.get(source)
  }
  function sway(node, strength) {
    windTargets.push({ node, strength, x: node.rotation.x, z: node.rotation.z, phase: windTargets.length * 1.7 })
  }
  const ledOn = new THREE.Color(), ledOff = new THREE.Color()
  const labels = [], practicalLights = [], windowLights = []
  const geometryCache = new Map()
  let textureSeed = 1283
  const random = () => { textureSeed = (textureSeed * 1664525 + 1013904223) >>> 0; return textureSeed / 4294967296 }

  function canvasTexture(size, draw, repeat = [1, 1]) {
    const canvas = document.createElement("canvas")
    canvas.width = canvas.height = size
    const context = canvas.getContext("2d")
    draw(context, size)
    const texture = new THREE.CanvasTexture(canvas)
    texture.colorSpace = THREE.SRGBColorSpace
    texture.wrapS = texture.wrapT = THREE.RepeatWrapping
    texture.repeat.set(...repeat)
    texture.anisotropy = Math.min(renderer.capabilities.getMaxAnisotropy(), 8)
    return texture
  }
  const woodTexture = canvasTexture(512, (context, size) => {
    context.fillStyle = "#eee9e2"
    context.fillRect(0, 0, size, size)
    for (let row = 0; row < 8; row++) {
      const y = row * 64
      context.fillStyle = row % 2 ? "rgba(95,75,55,.045)" : "rgba(255,255,255,.05)"
      context.fillRect(0, y + 2, size, 60)
      context.strokeStyle = "rgba(75,58,42,.16)"
      context.strokeRect(0, y, size, 64)
      for (let grain = 0; grain < 12; grain++) {
        const gy = y + 6 + random() * 52
        context.beginPath()
        context.moveTo(0, gy)
        context.bezierCurveTo(140, gy + random() * 8, 360, gy - random() * 7, size, gy + random() * 4)
        context.strokeStyle = `rgba(83,62,43,${0.025 + random() * 0.035})`
        context.stroke()
      }
    }
  }, [2, 2])
  const weaveTexture = canvasTexture(256, (context, size) => {
    context.fillStyle = "#e5e5e5"
    context.fillRect(0, 0, size, size)
    for (let i = 0; i < size; i += 4) {
      context.strokeStyle = i % 8 ? "rgba(255,255,255,.20)" : "rgba(45,45,45,.10)"
      context.beginPath(); context.moveTo(0, i); context.lineTo(size, i); context.stroke()
      context.strokeStyle = "rgba(45,45,45,.055)"
      context.beginPath(); context.moveTo(i, 0); context.lineTo(i, size); context.stroke()
    }
  }, [3, 2])
  const grassTexture = canvasTexture(256, (context, size) => {
    context.fillStyle = "#e2e5df"
    context.fillRect(0, 0, size, size)
    for (let i = 0; i < 1600; i++) {
      const shade = 150 + Math.floor(random() * 85)
      context.fillStyle = `rgba(${shade},${shade},${shade},.22)`
      context.fillRect(random() * size, random() * size, 1, 2 + random() * 2)
    }
  }, [6, 4])
  const screenTexture = canvasTexture(512, (context, size) => {
    context.fillStyle = "#17211f"
    context.fillRect(0, 0, size, size)
    context.fillStyle = "#26332f"
    context.fillRect(0, 0, size, 44)
    ;["#d97706", "#d6b95f", "#16a34a"].forEach((color, index) => {
      context.fillStyle = color
      context.beginPath(); context.arc(22 + index * 22, 22, 5, 0, Math.PI * 2); context.fill()
    })
    for (let row = 0; row < 13; row++) {
      const y = 76 + row * 30
      context.fillStyle = "rgba(163,184,174,.22)"
      context.fillRect(28, y, 20, 8)
      context.fillStyle = row % 3 ? "#789c8a" : "#818cf8"
      context.fillRect(68 + (row % 4) * 16, y, 120 + (row * 37) % 180, 8)
      context.fillStyle = "rgba(196,216,204,.32)"
      context.fillRect(270 + (row % 4) * 16, y, 55 + (row % 2) * 48, 8)
    }
  })
  // Floor textures use world-sized repeats, so small rooms do not stretch their tiles.
  const tileTexture = canvasTexture(256, (context, size) => {
    context.fillStyle = "#d9d6ce"
    context.fillRect(0, 0, size, size)
    for (let row = 0; row < 4; row++) for (let col = 0; col < 4; col++) {
      context.fillStyle = (row + col) % 2 ? "#faf8f2" : "#f0ede5"
      context.fillRect(col * 64 + 2, row * 64 + 2, 60, 60)
    }
  })
  const plankTexture = canvasTexture(512, (context, size) => {
    context.fillStyle = "#c4b8a4"
    context.fillRect(0, 0, size, size)
    for (let row = 0; row < 8; row++) for (let col = -1; col < 3; col++) {
      const x = col * 256 + (row % 2) * 128, y = row * 64
      const shade = 226 + Math.floor(random() * 22)
      context.fillStyle = `rgb(${shade},${shade - 7},${shade - 19})`
      context.fillRect(x + 1, y + 1, 254, 62)
      context.strokeStyle = "rgba(101,80,54,.12)"
      for (let line = 0; line < 5; line++) {
        const gy = y + 8 + line * 10
        context.beginPath(); context.moveTo(x + 6, gy)
        context.bezierCurveTo(x + 80, gy - 3, x + 160, gy + 4, x + 250, gy)
        context.stroke()
      }
    }
  })
  const roomFloors = []
  function roomFloor(room, width, depth) {
    const tiled = ["kitchen", "restrooms", "server"].includes(room.key)
    const texture = (tiled ? tileTexture : plankTexture).clone()
    texture.repeat.set(width / (tiled ? 4 : 8), depth / (tiled ? 4 : 8))
    texture.needsUpdate = true
    const material = new THREE.MeshStandardMaterial({ map: texture, roughness: tiled ? 0.65 : 0.85 })
    roomFloors.push({ material, key: room.key })
    const floor = new THREE.Mesh(new THREE.PlaneGeometry(width, depth), material)
    floor.rotation.x = -Math.PI / 2
    floor.receiveShadow = true
    return floor
  }
  mats.wood.map = woodTexture
  mats.rug.map = weaveTexture
  mats.fabric.map = weaveTexture
  const fabricBump = weaveTexture.clone()
  fabricBump.colorSpace = THREE.NoColorSpace
  fabricBump.needsUpdate = true
  mats.fabric.bumpMap = mats.rug.bumpMap = fabricBump
  mats.fabric.bumpScale = 0.012
  mats.rug.bumpScale = 0.008
  mats.grass.map = grassTexture
  mats.screen.map = screenTexture
  const shadowTexture = canvasTexture(128, (context, size) => {
    const gradient = context.createRadialGradient(size / 2, size / 2, 0, size / 2, size / 2, size / 2)
    gradient.addColorStop(0, "rgba(24,24,27,.48)")
    gradient.addColorStop(0.45, "rgba(24,24,27,.20)")
    gradient.addColorStop(1, "rgba(24,24,27,0)")
    context.fillStyle = gradient
    context.fillRect(0, 0, size, size)
  })
  const shadowMaterial = new THREE.MeshBasicMaterial({ map: shadowTexture, transparent: true, opacity: 0.48, depthWrite: false, toneMapped: false })
  const windowTexture = canvasTexture(128, (context, size) => {
    const glow = context.createLinearGradient(0, 0, 0, size)
    glow.addColorStop(0, "rgba(255,244,213,.75)")
    glow.addColorStop(1, "rgba(255,244,213,0)")
    context.fillStyle = glow
    context.fillRect(8, 0, 112, 128)
    context.clearRect(61, 0, 6, 128)
    context.clearRect(0, 38, 128, 5)
  })

  const cast = (mesh) => { mesh.castShadow = true; mesh.receiveShadow = true; return mesh }
  const flat = (mesh) => { mesh.castShadow = false; return mesh }
  function roundedBoxGeometry(w, h, d) {
    const smallest = Math.min(w, h, d)
    if (smallest < 0.055) {
      const key = `box:${w}:${h}:${d}`
      if (!geometryCache.has(key)) geometryCache.set(key, new THREE.BoxGeometry(w, h, d))
      return geometryCache.get(key)
    }
    const radius = Math.min(0.16, smallest * 0.26)
    const key = `${w}:${h}:${d}:${radius}`
    if (geometryCache.has(key)) return geometryCache.get(key)
    const width = w - radius * 2, height = h - radius * 2, corner = Math.min(radius * 1.5, width / 2, height / 2)
    const shape = new THREE.Shape()
    shape.moveTo(-width / 2 + corner, -height / 2)
    shape.lineTo(width / 2 - corner, -height / 2)
    shape.quadraticCurveTo(width / 2, -height / 2, width / 2, -height / 2 + corner)
    shape.lineTo(width / 2, height / 2 - corner)
    shape.quadraticCurveTo(width / 2, height / 2, width / 2 - corner, height / 2)
    shape.lineTo(-width / 2 + corner, height / 2)
    shape.quadraticCurveTo(-width / 2, height / 2, -width / 2, height / 2 - corner)
    shape.lineTo(-width / 2, -height / 2 + corner)
    shape.quadraticCurveTo(-width / 2, -height / 2, -width / 2 + corner, -height / 2)
    const geometry = new THREE.ExtrudeGeometry(shape, { depth: Math.max(0.01, d - radius * 2), bevelEnabled: true, bevelSegments: 2, steps: 1, bevelSize: radius, bevelThickness: radius, curveSegments: 3 })
    geometry.center()
    geometryCache.set(key, geometry)
    return geometry
  }
  function box(w, h, d, mat, x, y, z, parent) {
    const mesh = cast(new THREE.Mesh(roundedBoxGeometry(w, h, d), mat))
    mesh.position.set(x, y + h / 2, z)
    ;(parent || scene).add(parent ? mesh : shifted(mesh))
    return mesh
  }
  function cylinder(r, h, mat, x, y, z, parent, topRadius = r) {
    const mesh = cast(new THREE.Mesh(new THREE.CylinderGeometry(topRadius, r, h, 24), mat))
    mesh.position.set(x, y + h / 2, z)
    ;(parent || scene).add(parent ? mesh : shifted(mesh))
    return mesh
  }
  function ball(r, mat, x, y, z, parent) {
    const key = `sphere:${r}`
    if (!geometryCache.has(key)) geometryCache.set(key, new THREE.SphereGeometry(r, 18, 12))
    const mesh = cast(new THREE.Mesh(geometryCache.get(key), mat))
    mesh.position.set(x, y + r, z)
    ;(parent || scene).add(parent ? mesh : shifted(mesh))
    return mesh
  }
  function cone(r, h, mat, x, y, z, parent) {
    const mesh = cast(new THREE.Mesh(new THREE.ConeGeometry(r, h, 20), mat))
    mesh.position.set(x, y, z)
    ;(parent || scene).add(mesh)
    return mesh
  }
  function rod(start, end, radius, mat, parent) {
    const from = new THREE.Vector3(...start), to = new THREE.Vector3(...end)
    const direction = to.clone().sub(from)
    const mesh = cast(new THREE.Mesh(new THREE.CylinderGeometry(radius, radius, direction.length(), 10), mat))
    mesh.position.copy(from).add(to).multiplyScalar(0.5)
    mesh.quaternion.setFromUnitVectors(new THREE.Vector3(0, 1, 0), direction.normalize())
    parent.add(mesh)
    return mesh
  }
  function contactShadow(x, z, w, d, parent) {
    const shadow = new THREE.Mesh(new THREE.PlaneGeometry(w, d), shadowMaterial)
    shadow.rotation.x = -Math.PI / 2
    shadow.position.set(x, 0.065, z)
    ;(parent || scene).add(parent ? shadow : shifted(shadow))
    return shadow
  }
  function plant(x, z) {
    const group = new THREE.Group()
    group.position.set(x, 0.05, z)
    scene.add(shifted(group))
    cylinder(0.28, 0.48, mats.wood, 0, 0, 0, group, 0.34)
    cylinder(0.29, 0.035, mats.rack, 0, 0.46, 0, group)
    for (let i = 0; i < 9; i++) {
      const angle = i * 2.4, height = 0.72 + (i % 4) * 0.18, spread = 0.23 + (i % 3) * 0.11
      const end = [Math.cos(angle) * spread, height, Math.sin(angle) * spread]
      rod([0, 0.43, 0], end, 0.015, mats.felt, group)
      const leaf = ball(0.24 + (i % 2) * 0.04, mats.plant, ...end, group)
      leaf.scale.set(0.7, 1.35, 0.32)
      leaf.rotation.set(Math.sin(angle) * 0.4, angle, Math.cos(angle) * 0.55)
      sway(leaf, 0.055)
    }
    contactShadow(0, 0, 1.3, 1.3, group)
  }
  function mug(x, y, z, parent, mat = mats.accent) {
    mat = ceramic(mat)
    cylinder(0.075, 0.16, mat, x, y, z, parent === scene ? null : parent, 0.09)
    const handle = new THREE.Mesh(new THREE.TorusGeometry(0.065, 0.016, 6, 14, Math.PI * 1.7), mat)
    handle.position.set(x + 0.085, y + 0.09, z)
    handle.rotation.z = -Math.PI * 0.85
    ;(parent || scene).add(parent === scene ? shifted(handle) : handle)
  }
  function desk(x, z) {
    const group = new THREE.Group()
    group.position.set(x, 0.05, z)
    scene.add(shifted(group))
    box(2, 0.12, 0.9, mats.wood, 0, 0.70, 0, group)
    ;[-0.82, 0.82].forEach((dx) => [-0.32, 0.32].forEach((dz) => box(0.055, 0.70, 0.055, mats.metal, dx, 0, dz, group)))
    box(0.82, 0.50, 0.065, mats.rack, 0, 0.91, -0.20, group)
    box(0.72, 0.40, 0.018, mats.screen, 0, 0.96, -0.16, group)
    box(0.055, 0.14, 0.055, mats.metal, 0, 0.79, -0.19, group)
    box(0.36, 0.025, 0.23, mats.metal, 0, 0.82, -0.13, group)
    box(0.62, 0.028, 0.22, mats.rack, 0, 0.83, 0.20, group)
    for (let row = 0; row < 3; row++) for (let col = 0; col < 8; col++) box(0.048, 0.012, 0.045, mats.metal, -0.25 + col * 0.071, 0.86, 0.13 + row * 0.065, group)
    ball(0.065, mats.metal, 0.48, 0.83, 0.20, group).scale.set(0.75, 0.42, 1)
    box(0.27, 0.03, 0.35, mats.floor, -0.68, 0.82, 0.10, group)
    rod([-0.78, 0.86, -0.02], [-0.58, 0.86, 0.24], 0.009, mats.accent, group)
    mug(0.70, 0.82, 0.13, group)
    box(0.52, 0.48, 0.65, mats.wall, -0.65, 0.12, 0, group)
    ;[0.24, 0.40].forEach((y) => box(0.16, 0.025, 0.025, mats.metal, -0.65, y, 0.34, group))
    cylinder(0.14, 0.035, mats.metal, -0.78, 0.84, -0.28, group)
    rod([-0.78, 0.87, -0.28], [-0.78, 1.34, -0.28], 0.018, mats.metal, group)
    rod([-0.78, 1.34, -0.28], [-0.53, 1.43, -0.16], 0.018, mats.metal, group)
    const shade = ball(0.13, mats.fabric, -0.53, 1.30, -0.16, group)
    shade.scale.set(1, 0.5, 1)
    cylinder(0.07, 0.14, mats.wood, 0.72, 0.83, -0.25, group)
    for (let i = 0; i < 3; i++) rod([0.69 + i * 0.025, 0.90, -0.25], [0.67 + i * 0.04, 1.09, -0.25], 0.008, mats.felt, group)

    contactShadow(0, 0.15, 2.8, 1.8, group)
  }
  // A chair faces -z when ry is 0.
  function chair(x, z, ry) {
    const group = new THREE.Group()
    group.position.set(x, 0.05, z)
    group.rotation.y = ry
    scene.add(shifted(group))
    box(0.07, 0.38, 0.07, mats.metal, 0, 0.10, 0, group)
    for (let i = 0; i < 5; i++) {
      const angle = i * Math.PI * 0.4
      rod([0, 0.14, 0], [Math.cos(angle) * 0.34, 0.07, Math.sin(angle) * 0.34], 0.022, mats.metal, group)
      ball(0.045, mats.rack, Math.cos(angle) * 0.34, 0.015, Math.sin(angle) * 0.34, group)
    }
    box(0.58, 0.13, 0.56, mats.fabric, 0, 0.44, 0, group)
    const back = box(0.58, 0.55, 0.10, mats.fabric, 0, 0.56, 0.26, group)
    back.rotation.x = -0.08
    ;[-1, 1].forEach((side) => {
      rod([side * 0.31, 0.48, 0.18], [side * 0.31, 0.72, 0.18], 0.018, mats.metal, group)
      box(0.07, 0.045, 0.36, mats.rack, side * 0.31, 0.70, 0.02, group)
    })
    contactShadow(0, 0, 1.1, 1.1, group)
  }
  function floorLamp(x, z) {
    const group = new THREE.Group()
    group.position.set(x, 0.05, z)
    scene.add(shifted(group))
    cylinder(0.20, 0.045, mats.metal, 0, 0, 0, group)
    cylinder(0.028, 1.55, mats.metal, 0, 0.04, 0, group)
    cone(0.34, 0.42, mats.lamp, 0, 1.62, 0, group)
    ball(0.075, mats.lamp, 0, 1.48, 0, group)
    const light = new THREE.PointLight(0xffd98a, 0.45, 4, 2)
    light.position.set(0, 1.42, 0)
    group.add(light)
    practicalLights.push(light)
  }
  // A bookshelf faces +z.
  function bookshelf(x, z) {
    const spines = [mats.accent, mats.felt, mats.fabric, mats.rug, mats.wood]
    box(2, 1.5, 0.06, mats.wood, x, 0.05, z - 0.17)
    ;[-1, 1].forEach((side) => box(0.06, 1.5, 0.4, mats.wood, x + side * 0.97, 0.05, z))
    for (let row = 0; row < 3; row++) {
      box(2, 0.05, 0.4, mats.wood, x, 0.05 + row * 0.48, z)
      for (let i = 0; i < 8; i++) {
        const book = box(0.17, 0.26 + ((i * 7 + row * 3) % 4) * 0.035, 0.26, spines[(i + row * 2) % spines.length], x - 0.8 + i * 0.23, 0.1 + row * 0.48, z + 0.02)
        box(0.10, 0.012, 0.012, mats.floor, 0, 0.05, 0.137, book)
      }
    }
  }
  function tree(x, z, size) {
    const group = new THREE.Group()
    group.position.set(x, 0, z)
    scene.add(group)
    cylinder(0.16 * size, 1.05 * size, mats.wood, 0, 0, 0, group, 0.11 * size)
    ;[[0, 2.05, 0, 0.95], [-0.65, 1.65, 0.18, 0.72], [0.62, 1.75, 0.12, 0.77], [0.1, 1.7, -0.58, 0.72]].forEach(([dx, y, dz, radius]) => {
      const crown = ball(radius * size, mats.plant, dx * size, (y - radius) * size, dz * size, group)
      crown.scale.y = 1.1
      sway(crown, 0.018)
    })
    for (let i = 0; i < 7; i++) {
      const angle = i * 2.4, radius = (0.32 + (i % 3) * 0.08) * size
      const crown = ball(radius, mats.plant, Math.cos(angle) * 0.82 * size, (1.85 + (i % 3) * 0.28) * size, Math.sin(angle) * 0.66 * size, group)
      crown.scale.y = 0.85
      sway(crown, 0.025)
    }
    ;[-1, 1].forEach((side) => rod([0, 0.65 * size, 0], [side * 0.58 * size, 1.65 * size, 0.1], 0.06 * size, mats.wood, group))
    contactShadow(0, 0, 2.2 * size, 2.2 * size, group)
  }
  function bench(x, z) {
    ;[-0.17, 0, 0.17].forEach((dz) => box(2, 0.065, 0.13, mats.wood, x, 0.4, z + dz))
    ;[0.58, 0.76].forEach((y) => box(2, 0.12, 0.065, mats.wood, x, y, z - 0.25))
    ;[-0.8, 0.8].forEach((dx) => {
      box(0.07, 0.4, 0.4, mats.metal, x + dx, 0, z)
      rod([x + dx, 0.38, z - 0.2], [x + dx, 0.85, z - 0.25], 0.025, mats.metal, scene)
    })
    contactShadow(x, z, 2.6, 1.2)
  }
  const umbrellas = []
  function cafeTable(x, z, shade) {
    cylinder(0.05, 2.74, mats.metal, x, 0.06, z)
    cylinder(0.34, 0.045, mats.metal, x, 0.05, z)
    cylinder(0.7, 0.07, mats.wood, x, 0.8, z)
    const umbrella = createUmbrella(THREE, { x, z, shade, metal: mats.metal, alwaysOpen: umbrellas.length === 0 })
    umbrellas.push(umbrella)
    scene.add(umbrella.group)
    ;[0, 2.1, 4.2].forEach((angle) => {
      const cx = x + Math.cos(angle) * 1.05, cz = z + Math.sin(angle) * 1.05
      cylinder(0.22, 0.12, mats.fabric, cx, 0.43, cz)
      cylinder(0.035, 0.42, mats.metal, cx, 0.06, cz)
      cylinder(0.18, 0.035, mats.metal, cx, 0.04, cz)
    })
    mug(x + 0.25, 0.88, z, scene, mats.wall)
    contactShadow(x, z, 3.4, 3.4)
  }

  // Text is drawn on a canvas so it can follow the theme.
  function textTexture(text, tone, size, bold) {
    const canvas = document.createElement("canvas")
    canvas.width = 512
    canvas.height = 128
    const texture = new THREE.CanvasTexture(canvas)
    texture.colorSpace = THREE.SRGBColorSpace
    labels.push(() => {
      const context = canvas.getContext("2d")
      context.clearRect(0, 0, canvas.width, canvas.height)
      context.font = `${bold ? 700 : 400} ${size}px "Atkinson Hyperlegible", system-ui, sans-serif`
      context.textAlign = "center"
      context.textBaseline = "middle"
      context.fillStyle = palette()[tone]
      context.fillText(text, canvas.width / 2, canvas.height / 2)
      texture.needsUpdate = true
    })
    return texture
  }
  function nameTexture(text) {
    const canvas = document.createElement("canvas")
    canvas.width = 512
    canvas.height = 128
    const texture = new THREE.CanvasTexture(canvas)
    texture.colorSpace = THREE.SRGBColorSpace
    labels.push(() => {
      const context = canvas.getContext("2d"), colors = palette()
      context.clearRect(0, 0, canvas.width, canvas.height)
      context.fillStyle = document.documentElement.classList.contains("dark") ? "rgba(24,24,27,.88)" : "rgba(255,255,255,.92)"
      context.strokeStyle = document.documentElement.classList.contains("dark") ? "rgba(244,244,245,.16)" : "rgba(24,24,27,.12)"
      context.lineWidth = 2
      context.beginPath()
      context.roundRect(12, 18, 488, 92, 18)
      context.fill()
      context.stroke()
      context.fillStyle = "#16a34a"
      context.beginPath(); context.arc(48, 64, 9, 0, Math.PI * 2); context.fill()
      context.font = '600 46px "Atkinson Hyperlegible", system-ui, sans-serif'
      context.textAlign = "center"
      context.textBaseline = "middle"
      context.fillStyle = colors.ink
      context.fillText(text, 278, 65)
      texture.needsUpdate = true
    })
    return texture
  }
  function floorLabel(text, x, z) {
    const label = new THREE.Mesh(new THREE.PlaneGeometry(4, 1),
      new THREE.MeshBasicMaterial({ map: textTexture(text, "muted", 52, false), transparent: true, depthWrite: false }))
    label.rotation.x = -Math.PI / 2
    label.position.set(x, 0.09, z)
    scene.add(label)
  }

  function wall(x1, z1, x2, z2) {
    const horizontal = z1 === z2
    const length = horizontal ? Math.abs(x2 - x1) : Math.abs(z2 - z1)
    box(horizontal ? length + WALL_T : WALL_T, WALL_H, horizontal ? WALL_T : length + WALL_T, mats.wall, (x1 + x2) / 2, 0.05, (z1 + z2) / 2, scene)
  }
  function wallWithDoor(x1, z1, x2, z2) {
    if (z1 === z2) {
      const middle = (x1 + x2) / 2
      wall(x1, z1, middle - DOOR / 2, z2)
      wall(middle + DOOR / 2, z1, x2, z2)
    } else {
      const middle = (z1 + z2) / 2
      wall(x1, z1, x2, middle - DOOR / 2)
      wall(x1, middle + DOOR / 2, x2, z2)
    }
  }
  function glassTop(room) {
    const [x1, z1, x2, z2] = bounds(room)
    ;[[x2 - x1, 0.05, (x1 + x2) / 2, z1], [x2 - x1, 0.05, (x1 + x2) / 2, z2], [0.05, z2 - z1, x1, (z1 + z2) / 2], [0.05, z2 - z1, x2, (z1 + z2) / 2]]
      .forEach(([w, d, x, z]) => flat(box(w, 1.1, d, mats.glass, x, 0.05 + WALL_H, z, scene)))
  }

  // Ground, corridors (two north-south, one across; both north-south ones exit to the south) and rooms.
  // The campus sits directly on the continuous terrain, without a display-plinth edge.
  ;[[3.5, 20, -11.25, 0], [32, 3.5, 6.5, 1.75], [3.5, 10, 7.25, -5], [3.5, 6.5, 7.25, 6.75], [9.5, 2, -17.75, -3]]
    .forEach(([w, d, x, z]) => flat(box(w, 0.04, d, mats.path, x, 0, z, scene)))
  wall(-13, -10, -9.5, -10)
  wall(5.5, -10, 9, -10)
  wall(22.5, 0, 22.5, 3.5)
  wall(-22.5, -4, -22.5, -2)
  wall(-13, 4.5, -13, 10)
  ROOMS.forEach((room) => {
    const [x1, z1, x2, z2] = bounds(room)
    flat(box(x2 - x1, 0.05, z2 - z1, mats.floor, (x1 + x2) / 2, 0, (z1 + z2) / 2, scene))
    const finish = roomFloor(room, x2 - x1, z2 - z1)
    finish.position.set((x1 + x2) / 2, 0.056, (z1 + z2) / 2)
    scene.add(finish)
    const sides = { n: [x1, z1, x2, z1], s: [x1, z2, x2, z2], w: [x1, z1, x1, z2], e: [x2, z1, x2, z2] }
    Object.keys(sides).forEach((side) => (side === room.door ? wallWithDoor : wall)(...sides[side]))
    box(x2 - x1, 0.055, 0.08, mats.wood, (x1 + x2) / 2, WALL_H + 0.05, z1, scene)
    if (room.door !== "n") box(x2 - x1, 0.12, 0.04, mats.wood, (x1 + x2) / 2, 0.06, z1 + 0.15, scene)
    if (["reception", "work", "meeting"].includes(room.key)) {
      const windowX = x2 - 2.1
      box(2.8, 0.94, 0.08, mats.wood, windowX, 0.22, z1 + 0.15, scene)
      box(2.58, 0.76, 0.025, mats.glass, windowX, 0.31, z1 + 0.20, scene)
      box(0.055, 0.77, 0.06, mats.wall, windowX, 0.31, z1 + 0.24, scene)
      box(2.6, 0.05, 0.06, mats.wall, windowX, 0.68, z1 + 0.24, scene)
      box(2.95, 0.06, 0.32, mats.floor, windowX, 0.20, z1 + 0.26, scene)
      const lightMaterial = new THREE.MeshBasicMaterial({ map: windowTexture, transparent: true, opacity: 0.18, depthWrite: false, toneMapped: false })
      const sunlight = new THREE.Mesh(new THREE.PlaneGeometry(3.1, 4.1), lightMaterial)
      sunlight.rotation.x = -Math.PI / 2
      sunlight.rotation.z = -0.18
      sunlight.position.set(windowX - 0.4, 0.065, z1 + 2.3)
      scene.add(sunlight)
      windowLights.push(lightMaterial)
      for (let i = 0; i < 3; i++) {
        const x = x1 + 0.65 + i * 0.6
        box(0.42, 0.65, 0.07, mats.wood, x, 0.36, z1 + 0.16, scene)
        box(0.34, 0.55, 0.02, i % 2 ? mats.fabric : mats.felt, x, 0.41, z1 + 0.21, scene)
        ball(0.10, mats.floor, x, 0.60, z1 + 0.23, scene).scale.z = 0.1
      }
    }
    floorLabel(places[room.key], x1 + 2.3, z2 - 0.7)
  })

  // Reception
  box(3.2, 1, 0.8, mats.wood, -14.75, 0.05, -5.2)
  box(0.6, 0.4, 0.05, mats.rack, -14.75, 1.05, -5.2)
  box(3.2, 0.12, 0.02, mats.accent, -14.75, 0.6, -4.79)
  chair(-14.75, -6.2, Math.PI)
  plant(-18.6, -7.6)
  box(2.4, 0.5, 0.8, mats.fabric, -17.8, 0.05, -3.4)
  flat(box(4, 0.02, 2.4, mats.rug, -17, 0.05, -3.6))
  box(1, 0.35, 0.6, mats.wood, -15.6, 0.05, -3.4)
  box(0.3, 0.02, 0.4, mats.floor, -15.6, 0.4, -3.4)
  floorLamp(-10.7, -7.8)

  // Work area: six desks, a whiteboard with notes, a cabinet.
  ;[[-7, -6.6], [-2.5, -4.6], [2, -6.6], [-7, -1.6], [-2.5, -1.6], [2, -1.6]].forEach(([x, z]) => desk(x, z))
  SEATS.slice(0, 6).forEach(seat => chair(seat.at[0], seat.at[1] + 1.5, 0))
  plant(4.6, -7.6)
  plant(-8.7, 0.6)
  box(4.1, 1.1, 0.04, mats.metal, -2, 0.5, -8.38)
  box(3.9, 0.95, 0.04, mats.floor, -2, 0.58, -8.35)
  ;[[-3.3, mats.lamp], [-2.8, mats.accent], [-1.2, mats.felt], [-0.7, mats.lamp]]
    .forEach(([x, mat], i) => flat(box(0.3, 0.3, 0.02, mat, x, 0.85 + (i % 2) * 0.25, -8.31)))
  box(1.2, 1.1, 0.5, mats.metal, 4.7, 0.05, -1)

  // Meeting room
  flat(box(8.5, 0.02, 4, mats.rug, 12.75, 0.05, -5.75))
  box(6.5, 0.14, 1.7, mats.wood, 12.75, 0.72, -5.75)
  ;[10.2, 15.3].forEach((x) => box(0.16, 0.67, 1.25, mats.metal, x, 0.05, -5.75))
  for (let i = 0; i < 4; i++) {
    chair(10.5 + i * 1.5, -7.2, Math.PI)
    chair(10.5 + i * 1.5, -4.3, 0)
  }
  box(3.15, 1.24, 0.08, mats.rack, 12.75, 0.35, -8.3)
  box(2.98, 1.08, 0.025, mats.screen, 12.75, 0.43, -8.24)
  ;[10.8, 12.75, 14.7].forEach((x, index) => {
    box(0.72, 0.035, 0.48, mats.metal, x, 0.88, -5.65)
    box(0.72, 0.46, 0.035, mats.rack, x, 0.90, -5.93)
    box(0.65, 0.39, 0.015, mats.screen, x, 0.94, -5.90)
    box(0.30, 0.018, 0.34, index % 2 ? mats.floor : mats.fabric, x + 0.58, 0.88, -5.70)
  })
  mug(15.55, 0.87, -5.35, scene, mats.wall)
  cylinder(0.11, 0.32, mats.glass, 9.95, 0.87, -5.35, null, 0.08)
  contactShadow(12.75, -5.75, 7.4, 3.2)

  // Coordination office
  desk(12.5, -1.4)
  plant(18.6, -1.7)
  box(2.2, 0.38, 0.8, mats.fabric, 17, 0.20, 0.7)
  box(2.2, 0.50, 0.20, mats.fabric, 17, 0.48, 1.02)
  ;[-0.85, 0.85].forEach((dx) => box(0.18, 0.52, 0.82, mats.fabric, 17 + dx, 0.18, 0.7))
  box(0.45, 0.34, 0.16, mats.rug, 16.35, 0.59, 0.75)
  bookshelf(16, -2.2)
  floorLamp(6.6, -2.1)

  // Kitchen
  box(0.8, 0.9, 5, mats.wall, -18.9, 0.05, 1.25)
  box(0.86, 0.09, 5.06, mats.wood, -18.9, 0.95, 1.25)
  for (let i = 0; i < 7; i++) box(0.025, 0.72, 0.035, mats.metal, -18.48, 0.16, -0.8 + i * 0.67)
  cylinder(0.9, 0.10, mats.wood, -14, 0.72, 1.5)
  cylinder(0.10, 0.67, mats.metal, -14, 0.05, 1.5)
  cylinder(0.42, 0.045, mats.metal, -14, 0.04, 1.5)
  ;[[-15.3, 1.5], [-12.7, 1.5], [-14, 0.2], [-14, 2.8]].forEach(([x, z]) => {
    cylinder(0.25, 0.12, mats.fabric, x, 0.43, z)
    cylinder(0.04, 0.40, mats.metal, x, 0.05, z)
    cylinder(0.19, 0.035, mats.metal, x, 0.04, z)
  })
  box(0.8, 1.9, 0.8, mats.rack, -18.9, 0.05, 4)
  box(0.035, 0.65, 0.04, mats.metal, -18.47, 1.05, 4.25)
  box(0.4, 0.45, 0.4, mats.rack, -18.9, 0.99, -0.6)
  box(0.30, 0.06, 0.26, mats.metal, -18.9, 1.40, -0.54)
  box(0.5, 0.025, 0.8, mats.metal, -18.9, 1.04, 1.8)
  const faucet = new THREE.Mesh(new THREE.TorusGeometry(0.16, 0.022, 8, 20, Math.PI), mats.metal)
  faucet.position.set(-18.85, 1.28, 1.50)
  faucet.rotation.y = Math.PI / 2
  scene.add(shifted(faucet))
  mug(-18.8, 1.04, 0, scene, mats.wall)
  mug(-18.95, 1.04, 0.35, scene)
  box(0.5, 0.3, 0.4, mats.metal, -18.9, 0.99, 3)
  cylinder(0.26, 0.08, mats.wall, -14, 0.82, 1.5)
  ball(0.09, mats.lamp, -14.08, 0.88, 1.45)
  ball(0.09, mats.felt, -13.92, 0.88, 1.48)
  ball(0.09, mats.accent, -14, 0.88, 1.6)
  contactShadow(-14, 1.5, 3.6, 3.6)

  // Open shelves, crockery and a backsplash give the kitchenette a readable working edge.
  box(0.08, 0.6, 4.7, mats.rug, -19.16, 1.04, 1.2)
  ;[1.47, 1.85].forEach((y) => {
    box(0.55, 0.055, 2.7, mats.wood, -19, y, 0.9)
    for (let i = 0; i < 5; i++) cylinder(0.09, 0.18, i % 2 ? mats.fabric : mats.wall, -18.91, y + 0.055, -0.15 + i * 0.42)
  })
  ;[-1.5, 1.2, 3.3].forEach((z) => box(0.025, 0.68, 0.72, mats.wood, -18.47, 0.15, z))

  // Lounge
  flat(box(5.4, 0.02, 3.2, mats.rug, -5.6, 0.05, 6.1))
  box(3.4, 0.35, 1, mats.fabric, -5.5, 0.20, 7.5)
  box(3.4, 0.55, 0.22, mats.fabric, -5.5, 0.48, 7.94)
  ;[-1.55, 1.55].forEach((dx) => box(0.25, 0.55, 1.04, mats.fabric, -5.5 + dx, 0.22, 7.5))
  ;[-0.75, 0, 0.75].forEach((dx) => {
    box(0.70, 0.14, 0.76, mats.fabric, -5.5 + dx, 0.54, 7.40)
    box(0.70, 0.43, 0.15, mats.fabric, -5.5 + dx, 0.70, 7.78)
  })
  box(1, 0.38, 2.6, mats.fabric, -8.6, 0.20, 5.6)
  box(0.22, 0.55, 2.6, mats.fabric, -9.02, 0.45, 5.6)
  box(1.6, 0.10, 0.9, mats.wood, -5.5, 0.43, 5.6)
  ;[-0.58, 0.58].forEach((dx) => [-0.28, 0.28].forEach((dz) => box(0.05, 0.40, 0.05, mats.metal, -5.5 + dx, 0.05, 5.6 + dz)))
  box(0.52, 0.055, 0.36, mats.floor, -5.85, 0.54, 5.60)
  box(0.46, 0.045, 0.32, mats.accent, -5.84, 0.60, 5.60)
  mug(-4.90, 0.54, 5.55, scene, mats.wall)
  box(0.5, 0.3, 0.18, mats.accent, -6.5, 0.68, 7.52)
  box(0.5, 0.3, 0.18, mats.felt, -4.5, 0.68, 7.52)
  box(2.8, 0.75, 1.5, mats.wood, 2, 0.05, 5.4)
  box(2.6, 0.06, 1.3, mats.felt, 2, 0.8, 5.4)
  ;[[1.4, 5.3, mats.lamp], [2.3, 5.6, mats.accent], [2.6, 5.1, mats.wall], [1.9, 5.5, mats.rack]].forEach(([x, z, mat]) => ball(0.07, mat, x, 0.86, z))
  plant(4.7, 7.7)
  bookshelf(-7, 2.3)
  floorLamp(-8.8, 7.8)
  box(0.9, 1.7, 0.8, mats.rack, 4.8, 0.05, 3)
  box(0.6, 0.45, 0.02, mats.screen, 4.8, 1.05, 3.41)
  box(0.7, 0.06, 0.25, mats.accent, 4.8, 0.85, 3.5)
  contactShadow(-5.5, 7.3, 4.2, 2.0)

  // Upholstery, a draped throw and the billiard rails add detail above the floor texture.
  ;[[-6.55, 7.50, mats.rug], [-4.35, 7.50, mats.floor], [-8.55, 5.0, mats.rug]].forEach(([x, z, material]) => {
    const pillow = ball(0.28, material, x, 0.66, z)
    pillow.scale.set(1.05, 0.8, 0.40)
    pillow.rotation.z = x < -5 ? 0.18 : -0.18
  })
  box(0.8, 0.025, 0.8, mats.rug, -5.3, 0.70, 7.42)
  box(0.8, 0.36, 0.025, mats.rug, -5.3, 0.35, 7.02)
  ;[-1, 1].forEach((side) => {
    box(2.8, 0.10, 0.10, mats.wood, 2, 0.84, 5.4 + side * 0.72)
    box(0.10, 0.10, 1.4, mats.wood, 2 + side * 1.35, 0.84, 5.4)
    ;[-1, 0, 1].forEach((hole) => cylinder(0.10, 0.015, mats.rack, 2 + hole * 1.23, 0.915, 5.4 + side * 0.61))
  })
  const cues = new THREE.Group()
  cues.position.set(3.9, 0.05, 4.8)
  scene.add(shifted(cues))
  box(0.6, 0.07, 0.3, mats.wood, 0, 0, 0, cues)
  for (let i = 0; i < 3; i++) rod([-0.2 + i * 0.2, 0.06, 0], [-0.16 + i * 0.2, 1.65, 0.1], 0.018, mats.wood, cues)

  // Restrooms
  box(0.1, WALL_H, 4.2, mats.wall, 9.25, 0.05, 6.1)
  ;[[7, 7.9], [8.4, 7.9], [10.1, 7.9], [11.5, 7.9]].forEach(([x, z]) => {
    box(0.9, 0.85, 0.6, mats.wall, x, 0.05, z)
    box(0.3, 0.02, 0.3, mats.metal, x, 0.9, z)
  })
  ;[6.6, 7.7, 10.8, 11.9].forEach((x) => {
    box(0.4, 0.4, 0.55, mats.wall, x, 0.05, 2.5)
    box(0.4, 0.5, 0.12, mats.wall, x, 0.45, 2.25)
  })
  ;[7.15, 8.25, 10.25, 11.35].forEach((x) => box(0.06, 1.1, 1.4, mats.metal, x, 0.05, 2.75))

  // Server room: racks with blinking lights.
  ;[13.7, 14.75, 17.9, 18.9].forEach((x) => {
    box(1, 2.1, 0.8, mats.rack, x, 0.05, 2.75)
    for (let unit = 0; unit < 7; unit++) {
      box(0.86, 0.018, 0.025, mats.metal, x, 0.22 + unit * 0.25, 3.16)
      box(0.045, 0.10, 0.04, mats.metal, x - 0.38, 0.29 + unit * 0.25, 3.17)
    }
    for (let row = 0; row < 3; row++) {
      for (let col = 0; col < 4; col++) {
        flat(box(0.08, 0.06, 0.02, (row + col) % 2 ? mats.ledA : mats.ledB, x - 0.27 + col * 0.18, 0.9 + row * 0.4, 3.16))
      }
    }
  })
  desk(16.5, 7.4)

  // Glass above the walls of the two rooms meant to be looked into.
  glassTop(ROOMS[2])
  glassTop(ROOMS[3])

  // Outside: street path, trees around, lamps, bike rack.
  flat(box(52, 0.02, 1.8, mats.path, 0, 0, 11.4))
  ;[-11.25, 7.25].forEach((x) => flat(box(3.5, 0.02, 0.6, mats.path, x, 0, 10.3)))
  ;[[-23, -11.8, 1.3], [-14, -12.3, 1.1], [-4, -12.5, 1.25], [7, -12.4, 1.15], [20, -12.2, 1.3],
    [-24, -2, 1], [24, -2, 1.1], [-24, 8, 1.15], [24, 8, 1]].forEach(([x, z, size]) => tree(x, z, size))
  ;[-18, -5, 1, 14].forEach((x) => {
    cylinder(0.06, 2.6, mats.metal, x, 0, 12.55)
    ball(0.2, mats.lamp, x, 2.55, 12.55)
  })
  for (let i = 0; i < 4; i++) {
    const arc = cast(new THREE.Mesh(new THREE.TorusGeometry(0.35, 0.03, 6, 16, Math.PI), mats.metal))
    arc.position.set(i * 0.6, 0, 10.35)
    arc.rotation.y = Math.PI / 2
    scene.add(arc)
  }

  flat(box(3.0, 0.025, 23.0, mats.path, -29, -0.01, 22.6, scene))
  flat(box(18, 0.025, 2.2, mats.path, -20, -0.01, 11.4, scene))

  // Park: lawn, paths, pond, benches, trees and flowers.
  // The garden shares the countryside terrain; no separately tinted lawn rectangle.
  flat(box(1.4, 0.02, 6, mats.path, -11.25, 0.03, 15.2))
  flat(box(13, 0.02, 1.4, mats.path, -9, 0.03, 17.5))
  flat(cylinder(2.5, 0.03, mats.water, -3.5, 0.03, 21))
  for (let i = 0; i < 13; i++) {
    const angle = i * Math.PI * 2 / 13
    const stone = ball(0.32 + (i % 3) * 0.07, mats.floor, -3.5 + Math.cos(angle) * 2.5, 0.01, 21 + Math.sin(angle) * 2.5)
    stone.scale.set(1.25, 0.55, 0.85)
    stone.rotation.y = angle
  }
  ;[[-4.3, 20.4], [-2.6, 21.4], [-4.2, 22]].forEach(([x, z]) => {
    flat(cylinder(0.31, 0.025, mats.felt, x, 0.08, z))
    ball(0.10, mats.fabric, x, 0.11, z).scale.set(1, 0.6, 1)
  })
  bench(-14, 16.3)
  bench(-7.5, 16.3)
  bench(-18.5, 19.5)
  ;[[-22, 14.5], [-20.5, 22], [-17.5, 13.9], [0.8, 14.2], [1.2, 21.6]]
    .forEach(([x, z], i) => tree(x, z, 0.85 + (i % 4) * 0.12))
  ;[[-15.5, 20.6, mats.lamp], [-15, 21.1, mats.accent], [-16, 21, mats.wall], [-6.5, 14.6, mats.accent], [-6, 15, mats.lamp], [-20, 16.4, mats.wall], [-19.6, 16.9, mats.lamp]]
    .forEach(([x, z, mat]) => ball(0.12, mat, x, 0.03, z))
  floorLabel(places.park, -21.5, 13.5)

  // Stepping stones and reeds sit outside the decorative walking paths.
  for (let i = 0; i < 7; i++) {
    const stone = cylinder(0.35, 0.035, mats.floor, -10.7 + i * 0.78, 0.055, 19.2 + Math.sin(i * 0.7) * 0.45)
    stone.scale.z = 0.68
    stone.rotation.y = i * 0.8
  }
  ;[[-5.7, 20.2], [-1.2, 21.6], [-4.5, 23.3]].forEach(([x, z]) => {
    for (let i = 0; i < 5; i++) {
      const dx = (i - 2) * 0.12, height = 0.45 + (i % 3) * 0.17
      const reed = rod([x + dx, 0.06, z], [x + dx * 1.5, height, z + 0.1], 0.025, mats.felt, scene)
      sway(reed, 0.018)
      ball(0.055, mats.wood, x + dx * 1.5, height, z + 0.1, scene).scale.y = 2.5
    }
  })

  // Compact planted borders keep the pathways and the silhouettes of walking Puckies clear.
  ;[[-22, -11], [-14, -11.8], [21, -11.6], [-23.6, 5.8], [23.3, 5.8], [-22, 21.8], [-14, 22.5], [-6.7, 22.8], [0.3, 22.5], [7.7, 14]].forEach(([x, z]) => {
    const bed = new THREE.Group()
    bed.position.set(x, 0.04, z)
    scene.add(bed)
    box(2.6, 0.22, 1.2, mats.wall, 0, 0, 0, bed)
    for (let i = 0; i < 7; i++) {
      const dx = (i % 4) * 0.55 - 0.82, dz = i < 4 ? -0.22 : 0.24
      const shrub = ball(0.34, mats.plant, dx, 0.15, dz, bed)
      shrub.scale.set(0.85, 1 + (i % 3) * 0.2, 0.8)
      sway(shrub, 0.035)
      for (let petal = 0; petal < 3; petal++) ball(0.09, i % 2 ? mats.fabric : mats.floor, dx + (petal - 1) * 0.11, 0.72 + (petal % 2) * 0.11, dz, bed)
    }
    contactShadow(0, 0, 3.2, 1.8, bed)
  })

  // Cafeteria: deck, kiosk with counter and awning, tables with umbrellas.
  flat(box(15, 0.06, 8.6, mats.wood, 15, 0, 17.5))
  box(4, 2.2, 1.6, mats.wall, 19.5, 0.06, 14.3)
  box(4.2, 1, 0.5, mats.wood, 19.5, 0.06, 15.5)
  box(4.6, 0.1, 1.8, mats.fabric, 19.5, 2.3, 15.4)
  box(0.5, 0.45, 0.4, mats.rack, 20.6, 1.06, 15.5)
  ;[18.3, 18.6, 18.9].forEach((x) => cylinder(0.06, 0.12, mats.wall, x, 1.06, 15.55))
  // Slatted counter, serving hatch and scalloped valance distinguish the cafe from an office desk.
  for (let i = 0; i < 14; i++) box(0.045, 0.78, 0.035, mats.floor, 17.65 + i * 0.28, 0.14, 15.77)
  box(2.8, 1.05, 0.06, mats.rack, 19.4, 0.95, 15.13)
  box(2.9, 0.07, 0.32, mats.wood, 19.4, 0.94, 15.25)
  box(0.65, 0.46, 0.4, mats.metal, 20.1, 1.08, 15.52)
  ;[19.95, 20.2].forEach((x) => cylinder(0.065, 0.12, mats.wall, x, 1.08, 15.76))
  for (let i = 0; i < 12; i++) {
    const trim = ball(0.19, mats.fabric, 17.4 + i * 0.38, 1.98, 16.27, scene)
    trim.scale.set(1, 0.7, 0.22)
  }
  cafeTable(9.8, 18.5, mats.fabric)
  cafeTable(13.5, 19.6, mats.lamp)
  cafeTable(17.5, 19.8, mats.felt)
  cafeTable(21, 18.2, mats.fabric)
  plant(8.1, 13.9)
  plant(22, 21.2)
  floorLabel(places.cafe, 10.2, 14.2)

  const specialistRooms = createSpecialRooms(THREE, rooms, mats)
  scene.add(specialistRooms.group)
  specialistRooms.centers.forEach((center, id) => floorLabel(places[id], center.x, center.z + 3.6))
  const details = createOfficeDetails(THREE)
  scene.add(details.group)
  details.discoveries.forEach(discovery => { discovery.group.userData.discoveryId = discovery.id })
  batchStaticMeshes(THREE, scene, new Set([...windTargets.map(target => target.node), ...umbrellas.map(umbrella => umbrella.group), ...details.discoveries.map(discovery => discovery.group), ...details.animatedRoots]))

  const garden = createGardenLife(THREE)
  scene.add(garden.group)

  const world = createWorld(THREE)
  world.update(controls.target.x, controls.target.z)
  scene.add(world.group)

  // One figure per Puck, built from primitives.
  const figures = new Map()
  let free = 0
  puckies.forEach((puck, index) => {
    const seat = SEATS[index % SEATS.length]
    const group = new THREE.Group()
    group.position.set(seat.at[0], 0.05, seat.at[1])
    group.userData.id = puck.id
    let choice
    try { choice = localStorage.getItem(puck.mascotKey) } catch { /* Storage may be disabled. */ }
    const mascot = createMascot(THREE, choice)
    group.add(mascot.group)
    const ring = new THREE.Mesh(new THREE.TorusGeometry(0.48, 0.035, 8, 40), mats.accent)
    ring.rotation.x = Math.PI / 2
    ring.position.y = 0.06
    ring.visible = false
    const name = puck.name.length > 16 ? `${puck.name.slice(0, 15)}…` : puck.name
    const tag = new THREE.Sprite(new THREE.SpriteMaterial({ map: nameTexture(name), depthTest: false, transparent: true }))
    tag.scale.set(3.5, 0.875, 1)
    tag.position.y = 1.95
    tag.renderOrder = 10
    group.add(ring, tag)
    contactShadow(0, 0, 0.95, 0.95, group)
    scene.add(group)
    const cup = new THREE.Group()
    cup.name = "puck-coffee"
    mug(0, 0, 0, cup, mats.wall)
    cup.visible = false
    group.add(cup)
    const figure = { group, mascot, cup, seat, elapsed: 0, sitting: index < 6, drinking: false, working: puck.busy, mascotKey: puck.mascotKey, choice: mascotChoice(choice), ring, arms: mascot.arms, phase: index * 1.3, walking: false }
    if (!puck.busy) figure.walk = route(seat, free++)
    figures.set(puck.id, figure)
  })

  // The way out of the seat, through a corridor crossing, to a free spot in the park or at the cafeteria.
  function route(seat, turn) {
    const place = BREAKS[turn % BREAKS.length]
    const spot = place.spots[Math.floor(turn / BREAKS.length) % place.spots.length]
    const points = [seat.at, ...seat.out, HUBS[seat.hub], ...place[seat.hub], [spot, place.row]]
      .filter((point, i, all) => i === 0 || point[0] !== all[i - 1][0] || point[1] !== all[i - 1][1])
    const bench = turn % BREAKS.length === 0 && spot === -14
    if (bench) points.push([-14, 16.3])
    const lengths = [0]
    for (let i = 1; i < points.length; i++) lengths.push(lengths[i - 1] + Math.hypot(points[i][0] - points[i - 1][0], points[i][1] - points[i - 1][1]))
    return { points, lengths, total: lengths[lengths.length - 1], delay: turn * 7, bench, destination: turn % BREAKS.length === 1 ? "cafe" : "park" }
  }
  function pointAlong(walk, distance) {
    for (let i = 1; i < walk.points.length; i++) {
      if (distance > walk.lengths[i]) continue
      const from = walk.points[i - 1], to = walk.points[i]
      const part = (distance - walk.lengths[i - 1]) / (walk.lengths[i] - walk.lengths[i - 1])
      return [from[0] + (to[0] - from[0]) * part, from[1] + (to[1] - from[1]) * part, to[0] - from[0], to[1] - from[1]]
    }
    const last = walk.points[walk.points.length - 1]
    return [last[0], last[1], 0, 0]
  }
  function step(figure, time, delta) {
    const walk = figure.walk, walkTime = walk.total / SPEED
    const clock = (figure.elapsed + walk.delay) % (REST_HOME + REST_AWAY + walkTime * 2)
    const away = clock - REST_HOME, back = away - walkTime - REST_AWAY
    const spot = pointAlong(walk, away < 0 ? 0 : back > 0 ? walk.total - back * SPEED : Math.min(away * SPEED, walk.total))
    figure.walking = away > 0 && (away < walkTime || back > 0)
    const segmentLength = Math.hypot(spot[2], spot[3])
    const distance = away < 0 ? 0 : back > 0 ? walk.total - back * SPEED : Math.min(away * SPEED, walk.total)
    const lane = figure.walking ? Math.min(0.46, distance * 0.4, (walk.total - distance) * 0.4) * (back > 0 ? -1 : 1) : 0
    if (segmentLength) { spot[0] += spot[3] / segmentLength * lane; spot[1] -= spot[2] / segmentLength * lane }
    const candidate = new THREE.Vector3(spot[0], figure.group.position.y, spot[1])
    const blocked = [...figures.values()].some(other => other !== figure && other.group.position.distanceTo(candidate) < 0.85 && other.group.position.distanceTo(candidate) < other.group.position.distanceTo(figure.group.position))
    if (blocked && figure.walking) { figure.walking = false; return }
    figure.elapsed += Math.min(delta, 0.1)
    figure.sitting = away <= 0 && SEATS.indexOf(figure.seat) < 6
    figure.onBench = !figure.walking && away > 0 && walk.bench
    figure.drinking = !figure.walking && away > 0 && walk.destination === "cafe"
    figure.group.position.x = spot[0]
    figure.group.position.z = spot[1]
    const sign = back > 0 ? -1 : 1
    const watchingPond = !figure.walking && spot[1] > 17 && spot[0] > -7
    const heading = figure.walking && (spot[2] || spot[3]) ? Math.atan2(sign * spot[2], sign * spot[3]) : figure.sitting ? Math.PI : watchingPond ? Math.atan2(-3.5 - spot[0], 21 - spot[1]) : 0
    const turn = Math.atan2(Math.sin(heading - figure.group.rotation.y), Math.cos(heading - figure.group.rotation.y))
    figure.group.rotation.y += turn * Math.min(1, delta * 7)
  }

  function disposeMascot(mascot) {
    const geometries = new Set(), materials = new Set()
    mascot.group.traverse((node) => { if (node.geometry) geometries.add(node.geometry); if (node.material) materials.add(node.material) })
    geometries.forEach((geometry) => geometry.dispose())
    materials.forEach((material) => material.dispose())
  }
  function refreshMascots(event) {
    figures.forEach((figure) => {
      if (event?.detail?.key && event.detail.key !== figure.mascotKey) return
      let choice
      try { choice = localStorage.getItem(figure.mascotKey) } catch { choice = "01" }
      choice = mascotChoice(event?.detail?.value ?? choice)
      if (choice === figure.choice) return
      figure.group.remove(figure.mascot.group)
      disposeMascot(figure.mascot)
      figure.mascot = createMascot(THREE, choice)
      figure.arms = figure.mascot.arms
      figure.choice = choice
      figure.group.add(figure.mascot.group)
    })
  }
  window.addEventListener("coworker-mascot:change", refreshMascots)
  window.addEventListener("storage", refreshMascots)

  let selected = null, lightMode = "auto", following = false, cameraGoal = null
  function stopFollowing() { following = false; cameraGoal = null; onFollowChange(false) }
  controls.addEventListener("start", stopFollowing)
  function framePoint(point, zoom = 2) {
    cameraGoal = { target: point.clone(), zoom }
    if (reducedMotion) {
      camera.position.add(point.clone().sub(controls.target))
      controls.target.copy(point)
      camera.zoom = zoom
      camera.updateProjectionMatrix()
      cameraGoal = null
    }
  }
  function updateCamera(delta) {
    if (following && selected && !reducedMotion) framePoint(figures.get(selected).group.position, 2.5)
    if (!cameraGoal) return
    const factor = reducedMotion ? 1 : 1 - Math.exp(-5 * Math.min(delta, 0.1))
    const offset = cameraGoal.target.clone().sub(controls.target).multiplyScalar(factor)
    camera.position.add(offset)
    controls.target.add(offset)
    camera.zoom += (cameraGoal.zoom - camera.zoom) * factor
    camera.updateProjectionMatrix()
    if (controls.target.distanceTo(cameraGoal.target) < 0.01 && Math.abs(camera.zoom - cameraGoal.zoom) < 0.01) cameraGoal = null
  }
  function paint() {
    const colors = palette(), dark = document.documentElement.classList.contains("dark")
    TINTED.forEach((key) => mats[key].color.set(colors[key]))
    roomFloors.forEach(({ material, key }) => material.color.set(FLOOR_COLORS[key][dark ? 1 : 0]))
    ceramicMaterials.forEach((material, source) => material.color.copy(source.color))
    mats.screen.color.set("#ffffff")
    mats.glass.color.set(dark ? "#71717a" : "#e7e5e4")
    mats.eye.color.set("#f4f4f5")
    mats.lamp.color.set(colors.lamp)
    mats.lamp.emissive.set(colors.lamp)
    ledOn.set(colors.lamp)
    ledOff.set(colors.rack)
    mats.ledA.color.copy(ledOn)
    mats.ledB.color.copy(ledOn)
    updateLighting()
    labels.forEach((draw) => draw())
    figures.forEach((figure, id) => {
      figure.ring.visible = id === selected
    })
  }

  const nightSky = new THREE.Color("#252a43"), daySky = new THREE.Color("#eee3d8"), duskSky = new THREE.Color("#bc94a0")
  const moonColor = new THREE.Color("#a8beed"), dayColor = new THREE.Color("#ffedcf"), duskColor = new THREE.Color("#ffb778")
  let lastLightingSecond = -1
  function updateLighting() {
    const { daylight, warmth } = lightMode === "day" ? { daylight: 1, warmth: 0 } : lightMode === "evening" ? { daylight: 0.25, warmth: 1 } : daylightAt()
    const night = 1 - daylight
    atmosphere.theme(night)
    scene.background.copy(nightSky).lerp(daySky, daylight).lerp(duskSky, warmth * 0.55)
    scene.fog.color.copy(scene.background)
    hemi.intensity = 1.1 + daylight * 1.3
    sun.intensity = 0.35 + daylight * 1.45 + warmth * 0.3
    sun.color.copy(moonColor).lerp(dayColor, daylight).lerp(duskColor, warmth)
    fill.intensity = 0.65 + daylight * 0.07
    renderer.toneMappingExposure = 1.05 + night * 0.07
    mats.glass.emissive.set("#ffc785")
    mats.glass.emissiveIntensity = night * 0.4
    mats.lamp.emissiveIntensity = 0.65 + night * 1.15
    practicalLights.forEach(light => { light.intensity = 0.65 + night * 3.35 })
    windowLights.forEach(material => { material.opacity = 0.025 + daylight * 0.155 })
  }

  // Picking ignores drags, so turning the view never selects a Puck.
  const raycaster = new THREE.Raycaster(), pointer = new THREE.Vector2()
  const targets = [...figures.values()].map((figure) => figure.group).concat(details.discoveries.map(discovery => discovery.group))
  let pressedAt = null
  function hit(event) {
    const rect = renderer.domElement.getBoundingClientRect()
    pointer.set(((event.clientX - rect.left) / rect.width) * 2 - 1, -((event.clientY - rect.top) / rect.height) * 2 + 1)
    raycaster.setFromCamera(pointer, camera)
    let node = raycaster.intersectObjects(targets, true)[0]?.object
    while (node && node.userData.id === undefined && node.userData.discoveryId === undefined) node = node.parent
    return node?.userData.discoveryId ? { discovery: node.userData.discoveryId } : node?.userData.id
  }
  const pressed = (event) => { pressedAt = [event.clientX, event.clientY] }
  const released = (event) => {
    if (!pressedAt) return
    const moved = Math.hypot(event.clientX - pressedAt[0], event.clientY - pressedAt[1])
    pressedAt = null
    const id = moved > 6 ? undefined : hit(event)
    if (id?.discovery) discover(id.discovery)
    else if (id !== undefined) onSelect(id)
  }
  function discover(id) {
    const discovery = details.discoveries.find(item => item.id === id)
    if (!discovery) return
    stopFollowing()
    framePoint(discovery.group.getWorldPosition(new THREE.Vector3()), 3)
    details.activate(id)
    onDiscover(id)
  }
  const hovered = (event) => { if (event.pointerType === "mouse") renderer.domElement.style.cursor = hit(event) === undefined ? "grab" : "pointer" }
  renderer.domElement.addEventListener("pointerdown", pressed)
  renderer.domElement.addEventListener("pointerup", released)
  renderer.domElement.addEventListener("pointermove", hovered)

  function resize() {
    const width = stage.clientWidth, height = stage.clientHeight
    if (!width || !height) return
    renderer.setSize(width, height, false)
    const aspect = width / height
    // Phones start close enough to recognise a Puck; pinch and two-finger pan reveal the grounds.
    const halfHeight = aspect < 1 ? 14 : Math.max(rooms.length ? 25 : 19, (rooms.length ? 33 : 28) / aspect)
    camera.left = -halfHeight * aspect
    camera.right = halfHeight * aspect
    camera.top = halfHeight
    camera.bottom = -halfHeight
    camera.updateProjectionMatrix()
  }
  const resizeObserver = new ResizeObserver(resize)
  resizeObserver.observe(stage)
  const themeObserver = new MutationObserver(paint)
  themeObserver.observe(document.documentElement, { attributes: true, attributeFilter: ["class"] })
  resize()
  paint()
  document.fonts?.ready.then(() => labels.forEach((draw) => draw()))

  const clock = new THREE.Clock()
  let frame = null, previousTime = 0
  function tick() {
    frame = requestAnimationFrame(tick)
    const wallSecond = Math.floor(Date.now() / 1000)
    if (wallSecond !== lastLightingSecond) { updateLighting(); lastLightingSecond = wallSecond }
    const time = clock.getElapsedTime()
    const delta = time - previousTime
    previousTime = time
    if (!reducedMotion) {
      mats.ledA.color.copy(Math.sin(time * 5) > 0 ? ledOn : ledOff)
      mats.ledB.color.copy(Math.sin(time * 3.1 + 1) > 0 ? ledOn : ledOff)
      figures.forEach((figure) => {
        if (figure.walk) step(figure, time, delta)
        figure.group.position.y = 0.05 + Math.abs(Math.sin(time * (figure.walking ? 8 : 1.6) + figure.phase)) * (figure.walking ? 0.1 : figure.sitting || figure.onBench ? 0 : 0.055)
        if (figure.ring.visible) {
          const pulse = 1 + Math.sin(time * 3.2) * 0.06
          figure.ring.scale.setScalar(pulse)
        }
      })
    }
    figures.forEach((figure) => {
      const greeting = !figure.working && (time + figure.phase) % 12 < 2 && [...figures.values()].some(other => other !== figure && !other.working && other.group.position.distanceTo(figure.group.position) < 2.4)
      figure.mascot.group.position.y = figure.sitting ? 0.42 : figure.onBench ? 0.32 : 0
      if (figure.working && figure.sitting) figure.group.rotation.y = Math.PI
      figure.cup.visible = figure.drinking
      const sip = reducedMotion ? 0 : Math.max(0, Math.sin(time * 1.5 + figure.phase))
      figure.cup.position.set(0.34, 0.55 + sip * 0.23, 0.43)
      figure.cup.rotation.x = -sip * 0.35
      animateMascot(figure.mascot, { time, phase: figure.phase, walking: figure.walking, working: figure.working || figure.drinking, greeting, reducedMotion, sitting: figure.sitting || figure.onBench })
    })
    if (!reducedMotion) windTargets.forEach(({ node, strength, x, z, phase }) => {
      node.rotation.x = x + Math.sin(time * 0.7 + phase) * strength * 0.6
      node.rotation.z = z + Math.sin(time * 0.9 + phase) * strength
    })
    details.update(time, reducedMotion)
    atmosphere.update(time, reducedMotion)
    const positions = [...figures.values()].map(figure => figure.group.position)
    garden.update(time, reducedMotion, positions)
    updateCamera(delta)
    umbrellas.forEach(umbrella => umbrella.update(positions, delta, reducedMotion, time))
    controls.update()
    world.update(controls.target.x, controls.target.z)
    renderer.render(scene, camera)
  }
  tick()

  return {
    discover,
    select(id) { if (!figures.has(id)) return; selected = id; paint(); framePoint(figures.get(id).group.position, 2.5) },
    follow() { if (!selected) return; following = !following; onFollowChange(following); if (following) framePoint(figures.get(selected).group.position, 2.5) },
    view(name) {
      stopFollowing()
      const views = { office: [0, 0, -3, 1.5], park: [-11, 0, 18, 2.2], cafe: [16, 0, 18, 2.5] }
      if (specialistRooms.centers.has(name)) { framePoint(specialistRooms.centers.get(name), 2.5); return }
      const view = views[name]
      if (view) framePoint(new THREE.Vector3(...view.slice(0, 3)), view[3])
    },
    atmosphere(mode) { lightMode = ["day", "evening"].includes(mode) ? mode : "auto"; updateLighting() },
    reset() { stopFollowing(); camera.position.copy(HOME); camera.zoom = 1; camera.updateProjectionMatrix(); controls.target.copy(FOCUS); controls.update() },
    dispose() {
      cancelAnimationFrame(frame)
      resizeObserver.disconnect()
      motionPreference.removeEventListener("change", motionChanged)
      themeObserver.disconnect()
      window.removeEventListener("coworker-mascot:change", refreshMascots)
      window.removeEventListener("storage", refreshMascots)
      controls.removeEventListener("start", stopFollowing)
      controls.dispose()
      scene.remove(details.group)
      details.dispose()
      scene.remove(world.group)
      world.dispose()
      scene.traverse((node) => {
        if (node.isInstancedMesh) node.dispose()
        node.geometry?.dispose()
        node.material?.map?.dispose()
        node.material?.dispose()
      })
      atmosphere.dispose()
      fabricBump.dispose()
      tileTexture.dispose()
      plankTexture.dispose()
      renderer.dispose()
      renderer.domElement.remove()
    }
  }
}
