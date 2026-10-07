import { Controller } from "@hotwired/stimulus"

// A click on the Puck's screen while the person holds it: the point is sent in the screenshot's own
// pixels, so the browser in the virtual machine clicks the same spot (CYRA-1016).
export default class extends Controller {
  static targets = ["image", "x", "y"]
  static values = { active: Boolean }

  point(event) {
    if (!this.activeValue) return
    const image = this.imageTarget
    const box = image.getBoundingClientRect()
    this.xTarget.value = Math.round((event.clientX - box.left) * image.naturalWidth / box.width)
    this.yTarget.value = Math.round((event.clientY - box.top) * image.naturalHeight / box.height)
    this.element.requestSubmit()
  }
}
