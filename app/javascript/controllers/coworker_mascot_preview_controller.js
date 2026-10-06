import { Controller } from "@hotwired/stimulus"

// Plays a mascot's celebrate row while the pointer or focus is on it. The atlas loads on first hover only.
const CELEBRATE_ROW = 4
const COLUMNS = [0, 1, 2, 3, 4, 5]

export default class extends Controller {
  static targets = ["portrait", "sprite"]
  static values = { mascot: String }

  disconnect() {
    this.stop()
  }

  play() {
    this.active = true
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return
    if (!this.spriteTarget.getAttribute("src")) {
      this.spriteTarget.src = `/coworkers/mascots/animations/${this.mascotValue}.webp`
      return
    }
    if (this.ready) this.start()
  }

  loaded() {
    this.ready = true
    if (this.active) this.start()
  }

  start() {
    this.animation?.cancel()
    this.portraitTarget.hidden = true
    this.spriteTarget.hidden = false
    const poses = [...COLUMNS, COLUMNS[0]].map(column => ({ transform: this.frame(column) }))
    this.animation = this.spriteTarget.animate(poses, { duration: 1200, iterations: Infinity, easing: `steps(${COLUMNS.length}, end)` })
  }

  stop() {
    this.active = false
    this.animation?.cancel()
    this.animation = null
    this.spriteTarget.hidden = true
    this.portraitTarget.hidden = false
  }

  frame(column) {
    return `translate(${-column * 100 / 6}%, ${-CELEBRATE_ROW * 100 / 6}%)`
  }
}
