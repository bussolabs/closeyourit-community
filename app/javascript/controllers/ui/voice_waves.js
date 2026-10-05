// The glowing waves of the approved prototype: three sine lines whose height follows the voice,
// faded to transparent at both ends so they dissolve instead of being cut (CYRA-908).
const WIDTH = 420
const HEIGHT = 110
const WAVES = [
  { rgb: "59,130,246", alpha: 0.95, freq: 0.03, speed: 0.11, amp: 1.0, width: 2.2 },
  { rgb: "6,182,212", alpha: 0.85, freq: 0.042, speed: -0.08, amp: 0.7, width: 1.8 },
  { rgb: "139,92,246", alpha: 0.75, freq: 0.022, speed: 0.06, amp: 0.55, width: 1.6 }
]

// size: the overlay keeps the default; the panel's composer passes its own, a short strip. The glow
// margin and blur shrink with the height so the lines are not clipped there.
export function drawWaves(canvas, level, phase, { width = WIDTH, height = HEIGHT } = {}) {
  const dpr = window.devicePixelRatio || 1
  if (canvas.width !== Math.round(width * dpr) || canvas.height !== Math.round(height * dpr)) {
    canvas.width = Math.round(width * dpr)
    canvas.height = Math.round(height * dpr)
  }
  const ctx = canvas.getContext("2d")
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
  ctx.clearRect(0, 0, width, height)

  const mid = height / 2
  const maxAmp = height / 2 - Math.min(18, height * 0.2)
  ctx.globalCompositeOperation = "lighter"
  ctx.shadowColor = "rgba(37,99,235,0.85)"
  ctx.shadowBlur = Math.min(14, height * 0.2)
  for (const wave of WAVES) {
    ctx.beginPath()
    for (let x = 0; x <= width; x += 2) {
      const envelope = Math.pow(Math.sin(Math.PI * x / width), 2)
      const amp = (1.2 + level * maxAmp * wave.amp) * envelope
      const y = mid + amp * Math.sin(x * wave.freq + phase * wave.speed)
      x === 0 ? ctx.moveTo(x, y) : ctx.lineTo(x, y)
    }
    const gradient = ctx.createLinearGradient(0, 0, width, 0)
    gradient.addColorStop(0, `rgba(${wave.rgb},0)`)
    gradient.addColorStop(0.3, `rgba(${wave.rgb},${wave.alpha})`)
    gradient.addColorStop(0.7, `rgba(${wave.rgb},${wave.alpha})`)
    gradient.addColorStop(1, `rgba(${wave.rgb},0)`)
    ctx.strokeStyle = gradient
    ctx.lineWidth = wave.width
    ctx.stroke()
  }
  ctx.globalCompositeOperation = "source-over"
  ctx.shadowBlur = 0
}
