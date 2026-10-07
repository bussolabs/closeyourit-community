import { Controller } from "@hotwired/stimulus"

// CYRA-1035 — while the host updates, ask every 5 seconds how it is going. The app restarts in the
// middle, so failed requests are expected: keep asking, and reload once the update has an outcome.
export default class extends Controller {
  static values = { url: String, interval: { type: Number, default: 5000 } }

  connect() {
    this.connected = true
    this.schedule()
  }

  disconnect() {
    this.connected = false
    if (this.timer) clearTimeout(this.timer)
  }

  schedule() {
    if (this.connected) this.timer = setTimeout(() => this.check(), this.intervalValue)
  }

  async check() {
    try {
      const response = await fetch(this.urlValue, { headers: { Accept: "application/json" }, cache: "no-store" })
      if (response.ok) {
        const { state } = await response.json()
        if (state !== "queued" && state !== "running") return window.location.reload()
      }
    } catch {
      // The app is restarting: the next round asks again.
    }
    this.schedule()
  }
}
