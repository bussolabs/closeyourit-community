import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["image"]

  connect() {
    this.index = 0
    this.imageTarget.src = this.imageUrl(this.index)
    this.motionPreference = window.matchMedia("(prefers-reduced-motion: reduce)")
    this.onMotionChange = () => this.schedule()
    this.motionPreference.addEventListener("change", this.onMotionChange)
    this.schedule()
  }

  disconnect() {
    clearInterval(this.timer)
    this.motionPreference.removeEventListener("change", this.onMotionChange)
  }

  schedule() {
    clearInterval(this.timer)
    if (document.hidden || this.motionPreference.matches) return

    this.preloadNext()
    this.timer = setInterval(() => this.crossfade(), 4000)
  }

  // Fade out, swap once hidden, fade back in when the next mascot has loaded (CYRA-992).
  crossfade() {
    this.index = (this.index + 1) % 20
    this.imageTarget.style.opacity = "0"
    setTimeout(() => {
      this.imageTarget.addEventListener("load", () => { this.imageTarget.style.opacity = "1" }, { once: true })
      this.imageTarget.src = this.imageUrl(this.index)
      this.preloadNext()
    }, 300)
  }

  preloadNext() {
    const image = new Image()
    image.src = this.imageUrl((this.index + 1) % 20)
  }

  imageUrl(index) {
    return `/coworkers/mascots/${String(index + 1).padStart(2, "0")}.webp`
  }
}
