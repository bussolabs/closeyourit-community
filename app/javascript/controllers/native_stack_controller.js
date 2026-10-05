import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["thread"]
  static values = { selected: Number }

  connect() { this.render() }

  select(event) {
    if (!(event.target instanceof HTMLSelectElement)) return
    const value = Number(event.target.value)
    if (!this.threadTargets.some(panel => Number(panel.dataset.nativeThread) === value)) return
    this.selectedValue = value
    this.render()
  }

  render() {
    for (const panel of this.threadTargets) panel.hidden = Number(panel.dataset.nativeThread) !== this.selectedValue
  }
}
