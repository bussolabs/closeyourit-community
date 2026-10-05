import { Controller } from "@hotwired/stimulus"

// Repeater generico per campi nested Rails (accepts_nested_attributes_for). Clona una <template> per
// aggiungere righe con indice unico; le righe NUOVE si rimuovono dal DOM, quelle PERSISTITE (con id) si
// marcano _destroy=1 e si nascondono. replaceRows(items) sostituisce tutte le righe: lo usano gli
// assistenti AI (compose/quick) SOLO sul form nuovo, dove non ci sono righe persistite da preservare.
export default class extends Controller {
  static targets = ["container", "template"]

  initialize() {
    // Seeded on the clock: new rows never collide with the server's 0..N. The index stays a plain
    // number: Rails drops nested attributes whose key is not one.
    this.counter = Date.now()
  }

  add() {
    this.addRow()
  }

  // values: mappa data-field → valore, per pre-compilare la riga (usato da replaceRows).
  addRow(values = {}) {
    const token = String(this.counter++)
    const html = this.templateTarget.innerHTML.replaceAll("NEW_RECORD", token)
    const fragment = document.createRange().createContextualFragment(html)
    const row = fragment.firstElementChild
    if (!row) return null

    Object.entries(values).forEach(([field, value]) => {
      if (value == null) return
      const input = row.querySelector(`[data-field='${field}']`)
      if (input) input.value = value
    })
    this.containerTarget.appendChild(row)
    return row
  }

  remove(event) {
    const row = event.target.closest("[data-nested-fields-target='row']")
    if (!row) return

    const idField = row.querySelector("input[data-field='id']")
    if (idField && idField.value) {
      const destroy = row.querySelector("[data-nested-fields-target='destroy']")
      if (destroy) destroy.value = "1"
      row.hidden = true
    } else {
      row.remove()
    }
  }

  replaceRows(items) {
    this.containerTarget.replaceChildren()
    ;(items || []).forEach((item) => this.addRow(item))
  }
}
