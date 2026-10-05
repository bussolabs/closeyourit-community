import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["image", "picker", "trigger", "option", "status"]
  static values = { key: String, saved: String, unavailable: String }

  connect() {
    this.refresh()
  }

  refresh() {
    try {
      this.render(localStorage.getItem(this.keyValue))
    } catch {
      this.render("01")
    }
  }

  sync(event) {
    if (event.detail.key === this.keyValue) this.render(event.detail.value)
  }

  storage(event) {
    if (event.key === this.keyValue || event.key === null) this.refresh()
  }

  select(event) {
    const value = event.currentTarget.dataset.value
    if (!this.valid(value)) return

    this.render(value)
    this.dispatch("change", { detail: { key: this.keyValue, value } })
    try {
      localStorage.setItem(this.keyValue, value)
      this.statusTarget.textContent = this.savedValue
      this.close()
    } catch {
      this.statusTarget.textContent = this.unavailableValue
    }
  }

  render(value) {
    const selected = this.valid(value) ? value : "01"
    this.imageTargets.forEach(image => { image.src = `/coworkers/mascots/${selected}.webp` })
    this.optionTargets.forEach(option => {
      option.setAttribute("aria-pressed", String(option.dataset.value === selected))
    })
  }

  valid(value) {
    return /^(0[1-9]|1[0-9]|20)$/.test(value)
  }

  toggle() {
    if (!this.pickerTarget.open) return
    this.optionTargets.find(option => option.getAttribute("aria-pressed") === "true")?.focus()
  }

  dismiss(event) {
    if (this.hasPickerTarget && !this.element.contains(event.target)) this.close(false)
  }

  close(restoreFocus = true) {
    if (!this.hasPickerTarget || !this.pickerTarget.open) return
    if (restoreFocus instanceof KeyboardEvent) restoreFocus.preventDefault()
    this.pickerTarget.open = false
    if (restoreFocus) this.triggerTarget.focus()
  }
}
