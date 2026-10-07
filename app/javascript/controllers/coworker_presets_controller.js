import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["catalog", "name", "instructions", "option", "mascotOption", "usedMark", "preset"]
  static values = { storagePrefix: String, basePath: String, pucks: Array, usedBy: String }

  connect() {
    this.drafts = new Map()
    this.selected = "blank"
    this.catalogTarget.hidden = false
    this.renderMascot("01")
    this.markSelected()
    this.markUsed()
  }

  choose(event) {
    const option = event.currentTarget.dataset
    this.drafts.set(this.selected, {
      name: this.nameTarget.value, instructions: this.instructionsTarget.value, mascot: this.mascot
    })
    this.selected = option.preset
    // The server applies the role's rules from its own catalog (CYRA-1025).
    if (this.hasPresetTarget) this.presetTarget.value = this.selected === "blank" ? "" : this.selected
    const draft = this.drafts.get(this.selected) || option
    this.nameTarget.value = draft.name
    this.instructionsTarget.value = draft.instructions
    this.renderMascot(draft.mascot)
    this.markSelected()
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
  }

  // Mascots live in this browser only: a Puck with no stored choice shows the default one.
  markUsed() {
    const users = new Map()
    this.pucksValue.forEach(puck => {
      let mascot = null
      try {
        mascot = localStorage.getItem(`${this.storagePrefixValue}:${puck.id}`)
      } catch {
        // Storage unavailable: every Puck shows the default mascot.
      }
      const value = this.valid(mascot) ? mascot : "01"
      users.set(value, [...(users.get(value) || []), puck.name])
    })
    this.usedMarkTargets.forEach(mark => { mark.hidden = !users.has(mark.dataset.mascot) })
    this.mascotOptionTargets.forEach(option => {
      const names = users.get(option.dataset.mascot)
      option.title = names ? `${option.dataset.name} · ${this.usedByValue.replace("%{names}", names.join(", "))}` : option.dataset.name
    })
  }

  valid(value) {
    return /^(0[1-9]|1[0-9]|20)$/.test(value)
  }

  renderMascot(value) {
    this.mascot = this.valid(value) ? value : "01"
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
