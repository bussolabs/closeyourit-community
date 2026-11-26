import { Controller } from "@hotwired/stimulus"

// CYRA-1156 — the channel form shows only the fields of the chosen kind (webhook or Slack app).
// Hidden, not removed: the server reads only the fields of the kind it receives.
export default class extends Controller {
  static targets = ["kind", "field"]

  connect() {
    this.refresh()
  }

  refresh() {
    this.fieldTargets.forEach((field) => {
      field.hidden = field.dataset.kind !== this.kindTarget.value
    })
  }
}
