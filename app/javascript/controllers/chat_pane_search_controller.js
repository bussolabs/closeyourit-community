import { Controller } from "@hotwired/stimulus"

// Narrows the conversation list to the rows whose data-search contains what was typed.
// Client side only: the list is already on the page, so no request is needed.
export default class extends Controller {
  static targets = ["input", "row", "empty"]

  filter() {
    const query = this.inputTarget.value.trim().toLowerCase()
    let shown = 0
    this.rowTargets.forEach((row) => {
      const match = !query || row.dataset.search.includes(query)
      row.hidden = !match
      if (match) shown += 1
    })
    if (this.hasEmptyTarget) this.emptyTarget.classList.toggle("hidden", shown > 0)
  }
}
