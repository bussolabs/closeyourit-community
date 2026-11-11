// A small environment map supplies soft reflections without a second scene render.
export function createAtmosphere(THREE) {
  const faces = Array.from({ length: 6 }, (_, side) => {
    const canvas = document.createElement("canvas")
    canvas.width = canvas.height = 128
    const context = canvas.getContext("2d")
    const light = context.createLinearGradient(0, 0, 0, 128)
    light.addColorStop(0, side === 3 ? "#aab6a1" : "#eaf4ff")
    light.addColorStop(0.55, "#fff4de")
    light.addColorStop(1, "#929f86")
    context.fillStyle = light; context.fillRect(0, 0, 128, 128)
    context.fillStyle = "rgba(255,255,255,.65)"
    context.fillRect(28, 16, 42, 64)
    context.fillStyle = "rgba(60,80,60,.12)"
    context.fillRect(0, 105, 128, 23)
    return canvas
  })
  const environment = new THREE.CubeTexture(faces)
  environment.colorSpace = THREE.SRGBColorSpace
  environment.needsUpdate = true
  const uniforms = { time: { value: 0 }, tint: { value: new THREE.Color("#82bac5") },
    environment: { value: environment }, night: { value: 0 } }
  const waterMaterial = new THREE.ShaderMaterial({
    transparent: true, depthWrite: false, uniforms,
    vertexShader: `
      varying vec3 worldPoint;
      void main() {
        vec4 world = modelMatrix * vec4(position, 1.0);
        worldPoint = world.xyz;
        gl_Position = projectionMatrix * viewMatrix * world;
      }`,
    fragmentShader: `
      uniform float time;
      uniform float night;
      uniform vec3 tint;
      uniform samplerCube environment;
      varying vec3 worldPoint;
      void main() {
        float waveA = sin(worldPoint.x * 8.0 + worldPoint.z * 3.0 + time * 0.8);
        float waveB = cos(worldPoint.z * 9.0 - worldPoint.x * 2.0 - time * 0.6);
        vec3 normal = normalize(vec3(waveA * 0.065, 1.0, waveB * 0.065));
        vec3 eye = normalize(cameraPosition - worldPoint);
        float fresnel = pow(1.0 - max(dot(eye, normal), 0.0), 3.0);
        vec3 reflection = textureCube(environment, reflect(-eye, normal)).rgb;
        float glint = pow(max(dot(reflect(normalize(vec3(0.4,-1.0,-0.3)), normal), eye), 0.0), 64.0);
        vec3 color = mix(tint, reflection * (1.0 - night * 0.6), 0.18 + fresnel * 0.4);
        color += glint * (0.12 - night * 0.07);
        gl_FragColor = vec4(color, 0.32 + fresnel * 0.18);
        #include <tonemapping_fragment>
        #include <colorspace_fragment>
      }`
  })
  const water = new THREE.Mesh(new THREE.CircleGeometry(2.45, 64), waterMaterial)
  water.name = "pond-surface"
  water.rotation.x = -Math.PI / 2
  water.position.set(-3.5, 0.19, 21)
  water.renderOrder = 1
  const ripples = Array.from({ length: 3 }, () => {
    const material = new THREE.MeshBasicMaterial({ color: "#dfefdc", transparent: true, opacity: 0,
      depthWrite: false, toneMapped: false })
    const ripple = new THREE.Mesh(new THREE.RingGeometry(0.94, 1, 48), material)
    ripple.rotation.x = -Math.PI / 2
    ripple.position.y = 0.2
    ripple.renderOrder = 2
    return ripple
  })
  return {
    environment, water, ripples,
    theme(night) { uniforms.night.value = Number(night); uniforms.tint.value.set("#82bac5").lerp(new THREE.Color("#3c788b"), Number(night)) },
    update(time, reducedMotion) {
      if (reducedMotion) { ripples.forEach(ripple => { ripple.visible = false }); return }
      uniforms.time.value = time
      ripples.forEach((ripple, index) => {
        const phase = (time + index * 4) % 14
        ripple.visible = phase < 2.8
        if (!ripple.visible) return
        // Fix the centre at the surfacing event rather than dragging a ring behind a fish.
        const birth = time - phase, fishAngle = birth * (0.26 + index * 0.025) + index * 1.8
        const radius = 0.85 + (index % 3) * 0.35
        ripple.position.x = -3.5 + Math.cos(fishAngle) * radius
        ripple.position.z = 21 + Math.sin(fishAngle) * radius * 0.78
        ripple.scale.setScalar(0.10 + phase * 0.18)
        ripple.material.opacity = Math.sin(phase / 2.8 * Math.PI) * 0.22
      })
    },
    dispose() { environment.dispose() }
  }
}
