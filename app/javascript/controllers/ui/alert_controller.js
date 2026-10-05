import { Controller } from "@hotwired/stimulus"

const HIDDEN = ["opacity-0", "translate-y-2"]
const SHOWN  = ["opacity-100", "translate-y-0"]
const AUTO_MS = 5000

// Toast dismissible: entra (slide+fade), auto-chiude dopo 5s, X chiude subito.
export default class extends Controller {
  connect() {
    this.element.classList.add(...HIDDEN)
    requestAnimationFrame(() => {
      this.element.classList.remove(...HIDDEN)
      this.element.classList.add(...SHOWN)
    })
    this.timer = setTimeout(() => this.dismiss(), AUTO_MS)
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
