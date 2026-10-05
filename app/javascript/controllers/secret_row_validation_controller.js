import { Controller } from "@hotwired/stimulus"

// Validate new rows before the request reaches the confirmation screen.
export default class extends Controller {
  static values = { message: String }

  validate(event) {
    const fields = Array.from(event.target.elements).filter((field) => field.name?.startsWith("values["))
    if (fields.some((field) => field.value.trim() !== "")) return

    event.preventDefault()
    event.stopImmediatePropagation()
    if (!fields[0]) return
    fields[0].setCustomValidity(this.messageValue)
    fields[0].reportValidity()
  }

  clear() {
    this.element.querySelectorAll("textarea").forEach((field) => field.setCustomValidity(""))
  }
}
