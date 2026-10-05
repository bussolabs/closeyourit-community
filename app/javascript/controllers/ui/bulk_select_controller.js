import { Controller } from "@hotwired/stimulus"

// Selezione multipla di righe in tabella: sincronizza select-all ↔ per-row, aggiorna il contatore e
// mostra/nasconde la bulk bar (via attributo [hidden], NON classe .hidden — vedi TS-TAILWIND-001).
// Al submit del form nel dialog inietta gli id selezionati come hidden input `incident_ids[]`.
//
//   <div data-controller="ui--bulk-select">
//     <input type="checkbox" data-ui--bulk-select-target="all"    data-action="change->ui--bulk-select#toggleAll">
//     <input type="checkbox" data-ui--bulk-select-target="checkbox" data-action="change->ui--bulk-select#update" value="…">
//     <div data-ui--bulk-select-target="bar" hidden>… <span data-ui--bulk-select-target="count">0</span> …</div>
//     <form data-action="submit->ui--bulk-select#injectIds"><div data-ui--bulk-select-target="ids"></div></form>
//   </div>
export default class extends Controller {
  static targets = ["all", "checkbox", "bar", "count", "ids"]

  update() {
    const checked = this.checkedBoxes
    if (this.hasCountTarget) this.countTarget.textContent = checked.length
    if (this.hasBarTarget) this.barTarget.hidden = checked.length === 0
    if (this.hasAllTarget) {
      this.allTarget.checked = checked.length > 0 && checked.length === this.checkboxTargets.length
      this.allTarget.indeterminate = checked.length > 0 && checked.length < this.checkboxTargets.length
    }
  }

  toggleAll() {
    this.checkboxTargets.forEach((box) => { box.checked = this.allTarget.checked })
    this.update()
  }

  // Ripopola il contenitore hidden con gli incident_ids[] selezionati appena prima del submit.
  injectIds() {
    if (!this.hasIdsTarget) return
    this.idsTarget.replaceChildren()
    this.checkedBoxes.forEach((box) => {
      const input = document.createElement("input")
      input.type = "hidden"
      input.name = "incident_ids[]"
      input.value = box.value
      this.idsTarget.appendChild(input)
    })
  }

  get checkedBoxes() {
    return this.checkboxTargets.filter((box) => box.checked)
  }
}
