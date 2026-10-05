import { Controller } from "@hotwired/stimulus"

// Each occurrence owns its choice; switching occurrences never mixes their evidence.
export default class extends Controller {
  static targets = ["choice", "panel"]
  static values = { view: { type: String, default: "derived" } }

  connect() { this.render() }

  select(event) { this.viewValue = event.params.view }

  // Turbo morph can replace panels without reconnecting their controller.
  panelTargetConnected() { this.render() }
  choiceTargetConnected() { this.render() }
  viewValueChanged() { this.render() }

  render() {
    const view = this.viewValue === "received" ? "received" : "derived"
    this.panelTargets.forEach(panel => { panel.hidden = panel.dataset.stackView !== view })
    this.choiceTargets.forEach(button => {
      button.setAttribute("aria-pressed", String(button.dataset.stackViewViewParam === view))
    })
  }
}
