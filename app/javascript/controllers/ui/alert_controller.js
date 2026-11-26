import { Controller } from "@hotwired/stimulus"

const HIDDEN = ["opacity-0", "translate-y-2"]
const SHOWN  = ["opacity-100", "translate-y-0"]

// Toast dismissible: entra (slide+fade), auto-chiude dopo 5s (o `duration`), X chiude subito.
// CYRA-1150: the toast with Undo stays 10s, and its button leaves with it.
export default class extends Controller {
  static values = { duration: { type: Number, default: 5000 } }

  connect() {
    this.element.classList.add(...HIDDEN)
    requestAnimationFrame(() => {
      this.element.classList.remove(...HIDDEN)
      this.element.classList.add(...SHOWN)
    })
    this.timer = setTimeout(() => this.dismiss(), this.durationValue)
  }

  disconnect() {
    if (this.timer) clearTimeout(this.timer)
  }

  dismiss() {
    if (this.timer) clearTimeout(this.timer)
    this.element.classList.remove(...SHOWN)
    this.element.classList.add(...HIDDEN)
    this.element.addEventListener("transitionend", () => this.element.remove(), { once: true })
  }
}
