import { Controller } from "@hotwired/stimulus"

// CYRA-1138 — how long the agent has been at work, from the attempt's real start, ticking once a second.
// The server writes the first value, so the page reads right before this connects or without JavaScript.
export default class extends Controller {
  static values = { since: String }

  connect() {
    this.start = Date.parse(this.sinceValue)
    this.tick()
    this.timer = setInterval(() => this.tick(), 1000)
  }

  disconnect() {
    clearInterval(this.timer)
  }

  tick() {
    const seconds = Math.max(0, Math.floor((Date.now() - this.start) / 1000))
    const hours = Math.floor(seconds / 3600)
    const minutes = Math.floor((seconds % 3600) / 60)
    const rest = String(seconds % 60).padStart(2, "0")
    this.element.textContent = hours > 0 ? `${hours}:${String(minutes).padStart(2, "0")}:${rest}` : `${minutes}:${rest}`
  }
}
