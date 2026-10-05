import { Controller } from "@hotwired/stimulus"

// Saved views section of the toolbar's Filters menu (CYRA-902): filters the entries by label. Opening and
// closing belong to ui--filter-bar; the save modal to ui--dialog on the same element.
export default class extends Controller {
  static targets = ["search", "option"]

  filter() {
    const q = this.hasSearchTarget ? this.searchTarget.value.toLowerCase() : ""
    this.optionTargets.forEach((row) => {
      row.hidden = q !== "" && !(row.dataset.label || "").includes(q)
    })
  }
}
