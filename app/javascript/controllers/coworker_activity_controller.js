import { Controller } from "@hotwired/stimulus"

// Each atlas has six rows: idle, walk, work, speak, celebrate, puzzled.
const PACES = [1, 1.3, 0.9, 0.85, 1.25, 1.05, 0.8, 1.35, 1.2, 1.4, 0.85, 0.8, 1.3, 1.2, 0.75, 0.9, 1.6, 1.05, 1.1, 1.15]
const COLUMNS = [0, 1, 2, 3, 4, 5]

export default class extends Controller {
  static targets = ["mascot", "portrait", "sprite", "status"]
  static values = { puck: String, key: String, runs: Array, labels: Object }

  connect() {
    this.runs = new Map(this.runsValue.map(run => [run.id, run]))
    this.motionPreference = window.matchMedia("(prefers-reduced-motion: reduce)")
    this.onMotionChange = () => this.animate()
    this.motionPreference.addEventListener("change", this.onMotionChange)
    this.visible = true
    this.observer = new IntersectionObserver(([entry]) => {
      if (this.visible === entry.isIntersecting) return
      this.visible = entry.isIntersecting
      this.animate()
    })
    this.observer.observe(this.mascotTarget)
    this.refresh()
    this.storage()
  }

  disconnect() {
    this.animation?.cancel()
    this.observer.disconnect()
    this.motionPreference.removeEventListener("change", this.onMotionChange)
  }

  storage(event) {
    if (event && event.key !== null && event.key !== this.keyValue) return
    try {
      this.loadMascot(localStorage.getItem(this.keyValue))
    } catch {
      this.loadMascot("01")
    }
  }

  mascotChanged(event) {
    if (event.detail.key === this.keyValue) this.loadMascot(event.detail.value)
  }

  loadMascot(value) {
    const selected = /^(0[1-9]|1[0-9]|20)$/.test(value) ? value : "01"
    if (selected === this.selected) return
    this.selected = selected
    this.ready = false
    this.animation?.cancel()
    this.portraitTarget.src = `/coworkers/mascots/${selected}.webp`
    this.portraitTarget.hidden = false
    this.spriteTarget.hidden = true
    this.spriteTarget.src = `/coworkers/mascots/animations/${selected}.webp`
  }

  loaded() {
    this.ready = true
    this.animate()
    this.spriteTarget.hidden = false
    this.portraitTarget.hidden = true
  }

  failed() {
    this.ready = false
    this.animation?.cancel()
    this.spriteTarget.hidden = true
    this.portraitTarget.hidden = false
  }

  stream(event) {
    const content = event.detail.newStream.querySelector("template")?.content
    if (!content) return
    // Read broadcasts even when their task card is outside the open panel.
    content.querySelectorAll("[data-coworker-run-id]").forEach(element => {
      if (element.dataset.coworkerPuckId !== this.puckValue) return
      const { coworkerRunId: id, status, coworkerKind: kind, coworkerCreatedAt: createdAt } = element.dataset
      this.runs.set(id, { id, status, kind, createdAt })
    })
    this.refresh()
  }

  refresh() {
    const runs = [...this.runs.values()].sort((a, b) => b.createdAt.localeCompare(a.createdAt))
    const current = runs.find(run => run.status === "running") || runs.find(run => run.status === "queued") || runs[0]
    const state = current?.status || "idle"
    const kind = current?.kind
    if (state === this.state && kind === this.kind) return
    this.state = state
    this.kind = kind
    this.element.dataset.activity = state
    this.statusTarget.textContent = this.labelsValue[state] || this.labelsValue.idle
    this.animate()
  }

  animate() {
    this.animation?.cancel()
    if (!this.ready) return
    const row = this.row()
    this.spriteTarget.style.transform = this.frame(row, 2)
    if (document.hidden || !this.visible || this.motionPreference.matches) return
    const pace = PACES[Number(this.selected) - 1]
    if (this.state === "stopped") return
    if (this.state === "idle") return this.idle(pace)
    if (["completed", "failed", "interrupted"].includes(this.state)) {
      const animation = this.play(COLUMNS.map(column => [row, column]), 1800 * pace, 1)
      if (this.state === "completed") animation.onfinish = () => {
        if (this.animation === animation && this.state === "completed") this.idle(pace)
      }
      return
    }
    const frames = this.state === "running"
      ? [...COLUMNS.map(column => [1, column]), ...[0, 1, 2].flatMap(() => COLUMNS.map(column => [row, column]))]
      : COLUMNS.map(column => [row, column])
    this.play(frames, frames.length * 180 * pace)
  }

  row() {
    if (this.state === "queued") return 1
    if (this.state === "running") return this.kind === "chat" ? 3 : 2
    if (this.state === "completed") return 4
    if (["failed", "interrupted"].includes(this.state)) return 5
    return 0
  }

  idle(pace) {
    this.play([0, 0, 0, 0, 0, 1, 2, 0, 0, 0].map(column => [0, column]), 4400 * pace)
  }

  play(frames, duration, iterations = Infinity) {
    const poses = [...frames, frames[0]].map(([row, column]) => ({ transform: this.frame(row, column) }))
    this.animation = this.spriteTarget.animate(poses, { duration, iterations, easing: `steps(${frames.length}, end)`, fill: "forwards" })
    return this.animation
  }

  frame(row, column) {
    return `translate(${-column * 100 / 6}%, ${-row * 100 / 6}%)`
  }
}
