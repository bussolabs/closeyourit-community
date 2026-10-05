import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["catalog", "name", "instructions", "option", "image", "picker", "mascotOption"]
  static values = { storagePrefix: String, basePath: String }

  connect() {
    this.drafts = new Map()
    this.selected = "blank"
    this.catalogTarget.hidden = false
    this.renderMascot("01")
    this.markSelected()
  }

  choose(event) {
    const option = event.currentTarget.dataset
    this.drafts.set(this.selected, {
      name: this.nameTarget.value, instructions: this.instructionsTarget.value, mascot: this.mascot
    })
    this.selected = option.preset
    const draft = this.drafts.get(this.selected) || option
    this.nameTarget.value = draft.name
    this.instructionsTarget.value = draft.instructions
    this.renderMascot(draft.mascot)
    this.markSelected()
    this.pickerTarget.open = false
    this.nameTarget.focus()
  }

  markSelected() {
    this.optionTargets.forEach(option => {
      option.setAttribute("aria-pressed", String(option.dataset.preset === this.selected))
    })
  }

  browse() {
    this.catalogTarget.scrollIntoView({ block: "start" })
    this.optionTargets[0].focus({ preventScroll: true })
  }

  chooseMascot(event) {
    this.renderMascot(event.currentTarget.dataset.mascot)
    this.pickerTarget.open = false
    this.pickerTarget.querySelector("summary").focus()
  }

  renderMascot(value) {
    this.mascot = /^(0[1-9]|1[0-9]|20)$/.test(value) ? value : "01"
    this.imageTarget.src = `/coworkers/mascots/${this.mascot}.webp`
    this.mascotOptionTargets.forEach(option => {
      option.setAttribute("aria-pressed", String(option.dataset.mascot === this.mascot))
    })
  }

  created(event) {
    const { success, fetchResponse } = event.detail
    if (!success || !fetchResponse?.redirected || !this.mascot) return

    const destination = fetchResponse.location
    const base = new URL(this.basePathValue, window.location.origin)
    if (destination.origin !== base.origin) return
    const prefix = `${base.pathname}/`
    if (!destination.pathname.startsWith(prefix)) return
    const id = destination.pathname.slice(prefix.length)
    if (!/^[0-9a-f-]{36}$/i.test(id)) return

    // The mascot remains browser-local; only a successful create redirect identifies its owner.
    try {
      localStorage.setItem(`${this.storagePrefixValue}:${id}`, this.mascot)
    } catch {
      // Storage may be unavailable; creation still succeeds with the default portrait.
    }
  }
}
