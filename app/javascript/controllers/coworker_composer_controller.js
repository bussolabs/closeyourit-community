import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input"]

  connect() {
    this.grow()
  }

  grow() {
    const input = this.inputTarget
    input.style.height = "auto"
    const height = input.scrollHeight + input.offsetHeight - input.clientHeight
    input.style.height = `${Math.min(height, 128)}px`
    input.style.overflowY = height > 128 ? "auto" : "hidden"
  }
}
