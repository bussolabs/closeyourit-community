import { Controller } from "@hotwired/stimulus"

// CYRA-1086 — when the project changes, the reporter follows the project owner (blank when the
// project has none, and the server then names whoever saves). A reporter picked by hand stays.
// The select is a Ui::SelectComponent: lookup by id, then "ui--select:refresh" to resync the widget.
export default class extends Controller {
  static values = { owners: { type: Object, default: {} } }

  connect() {
    this.followsProject = true
  }

  sync(event) {
    const select = this.element.querySelector("#reporter_id")
    if (!select) return

    if (event.target === select) {
      this.followsProject = false
      return
    }
    if (event.target.name !== "project_id" || !this.followsProject) return

    select.value = this.ownersValue[event.target.value] || ""
    select.dispatchEvent(new CustomEvent("ui--select:refresh"))
  }
}
