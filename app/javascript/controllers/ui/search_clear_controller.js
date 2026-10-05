import { Controller } from "@hotwired/stimulus"

// CYRA-883 — the ✕ in a search field: empties it and submits its own form, so the current filters and
// the remembered-filters marker travel with it, and lists whose bar sits outside a Turbo Frame (never
// redrawn) still clear the search they show. A type=button, never a submit: Enter in the field must
// keep searching, not hit the first submit button of the form.
export default class extends Controller {
  static targets = ["input"]

  clear() {
    this.inputTarget.value = ""
    this.inputTarget.form.requestSubmit()
  }
}
