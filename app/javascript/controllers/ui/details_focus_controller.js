import { Controller } from "@hotwired/stimulus"

// A <details> that opens an inline field (rename in place): opening it puts the caret in the field
// with its text selected, so the person can type right away. CYRA-1107
export default class extends Controller {
  toggle() {
    if (!this.element.open) return

    const field = this.element.querySelector("input:not([type=hidden]), textarea")
    field?.focus()
    field?.select?.()
  }
}
