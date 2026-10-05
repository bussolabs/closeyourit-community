import { Controller } from "@hotwired/stimulus"

// CYRA-985 — Ui::RangeFilterComponent. A preset or Apply writes the hidden field and submits the
// form. The two dates win over any preset (Monitoring::TimeRange.resolve), so they travel only while
// the field says "custom": checked when the form data is built, whoever submits.
export default class extends Controller {
  static targets = ["value", "bound"]
  static values = { custom: String }

  connect() {
    this.form = this.element.closest("form")
    this.strip = this.strip.bind(this)
    this.form?.addEventListener("formdata", this.strip)
  }

  disconnect() {
    this.form?.removeEventListener("formdata", this.strip)
  }

  strip(event) {
    if (this.valueTarget.value === this.customValue) return
    this.boundTargets.forEach((input) => event.formData.delete(input.name))
  }

  choose(event) {
    this.pick(event.currentTarget.dataset.value)
  }

  apply() {
    this.pick(this.customValue)
  }

  pick(value) {
    this.valueTarget.value = value
    this.element.open = false
    this.form?.requestSubmit()
  }
}
