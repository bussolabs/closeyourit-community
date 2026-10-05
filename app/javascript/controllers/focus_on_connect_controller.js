import { Controller } from "@hotwired/stimulus"

// Puts the cursor in the element as soon as it appears. Turbo does not honour autofocus when it
// redraws a frame, so the add field of a todo panel loses the cursor after every new item.
export default class extends Controller {
  connect() {
    this.element.focus()
  }
}
