import { Controller } from "@hotwired/stimulus"

// CYRA-924 — a project secrets row (DESIGN.md C64): the eye shows the values as plain text in the
// cells, the pencil opens the row's dialog to edit them. Values never sit in the page source
// (CYRA-202): both commands read them from the audited reveal endpoint, only when asked.
export default class extends Controller {
  static targets = ["masked", "value", "input", "description", "dialog", "revealButton", "hideButton"]
  static values = { open: Boolean, revealError: String }

  connect() {
    // The server re-renders the page with the dialog open after a failed save (422).
    if (this.openValue) this.edit()
  }

  reveal() {
    const token = this.nextToken()
    this.maskedTargets.forEach((el) => (el.hidden = true))
    this.valueTargets.forEach((el) => (el.hidden = false))
    this.toggleButtons(true)
    this.valueTargets.forEach(async (el) => {
      const value = await this.fetchValue(el.dataset.secretRevealUrl)
      if (this.token !== token) return
      el.textContent = value ?? this.revealErrorValue
    })
  }

  // Masking throws the revealed text away: left in the DOM it would stay readable.
  mask() {
    this.nextToken()
    this.valueTargets.forEach((el) => {
      el.textContent = ""
      el.hidden = true
    })
    this.maskedTargets.forEach((el) => (el.hidden = false))
    this.toggleButtons(false)
  }

  // A late answer never overwrites what the person already typed.
  edit() {
    if (!this.hasDialogTarget) return
    if (!this.dialogTarget.open) this.dialogTarget.showModal()
    this.originalValues = new Map()
    const token = this.nextToken()
    this.inputTargets.forEach(async (el) => {
      if (!el.dataset.secretRevealUrl) return
      const value = await this.fetchValue(el.dataset.secretRevealUrl)
      if (this.token !== token || !this.dialogTarget.open) return
      if (value === null) el.placeholder = this.revealErrorValue
      else if (el.value === "") {
        el.value = value
        this.originalValues.set(el, value)
      }
    })
  }

  // Unchanged values mean "preserve", especially while a description awaits approval. CYRA-987
  prepareSubmission() {
    this.nextToken()
    this.originalValues?.forEach((value, input) => {
      if (input.value === value) input.value = ""
    })
  }

  // From the cell menu: open the dialog on the row's description.
  editDescription() {
    this.edit()
    if (this.hasDescriptionTarget) this.descriptionTarget.focus()
  }

  cancel() {
    if (this.hasDialogTarget && this.dialogTarget.open) this.dialogTarget.close()
  }

  // Runs on every close (Cancel, Esc, backdrop): the fetched values leave the DOM with the dialog.
  reset() {
    this.nextToken()
    this.inputTargets.forEach((el) => (el.value = el.defaultValue))
    this.descriptionTargets.forEach((el) => (el.value = el.defaultValue))
  }

  backdrop(event) {
    if (event.target === this.dialogTarget) this.cancel()
  }

  async fetchValue(url) {
    if (!url) return null
    try {
      const response = await fetch(url, { headers: { Accept: "application/json" }, credentials: "same-origin" })
      if (!response.ok) return null
      const data = await response.json()
      return data.value ?? ""
    } catch {
      return null
    }
  }

  nextToken() {
    this.token = (this.token || 0) + 1
    return this.token
  }

  toggleButtons(revealed) {
    if (this.hasRevealButtonTarget) this.revealButtonTarget.hidden = revealed
    if (this.hasHideButtonTarget) this.hideButtonTarget.hidden = !revealed
  }
}
