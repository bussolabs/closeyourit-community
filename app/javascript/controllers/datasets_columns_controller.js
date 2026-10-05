import { Controller } from "@hotwired/stimulus"

// Colonne feature dinamiche del form dataset: aggiungi/rimuovi righe clonando un <template>, con
// indice incrementale nei name/id (features[N][...]) così righe rimosse/riordinate non collidono
// lato server. Toggle del campo "valori" (options) quando il tipo è category. Progressive
// enhancement: senza JS restano le righe già renderizzate dal server (l'utente non può aggiungerne,
// ma il form resta valido/submittabile).
//
// Il select "role" è un Ui::SelectComponent (regola forms-select): una foto è sempre Input, quindi
// quando kind=photo forziamo il valore e disabilitiamo la SOLA option "target" (non l'intero
// <select> — il componente non espone un modo per renderizzare il nativo già disabled, e il widget
// custom non propaga un disabled a livello di intero select; disabilitare l'opzione è la stessa
// garanzia funzionale — l'utente non può scegliere "target" — riusando il supporto option-level di
// ui/select_controller.js) + dispatch di "ui--select:refresh" perché il widget si ri-sincronizzi.
// syncRole() è condivisa da onKindChange() (l'utente cambia kind) e da connect() (righe già
// renderizzate dal server in edit, es. una colonna kind=photo esistente).
export default class extends Controller {
  static targets = ["list", "template", "empty"]
  static values = { index: Number }

  connect() {
    this.listTarget.querySelectorAll("[data-column-row]").forEach((row) => this.syncRole(row))
  }

  add(event) {
    event.preventDefault()
    // Clona il contenuto inerte del <template> (nessuna stringa HTML costruita a runtime) e imposta
    // l'indice numerico nei name/id delle sole input/select clonate (il Ui::SelectComponent del
    // ruolo renderizza un id — senza questa sostituzione due righe aggiunte in sequenza dallo
    // stesso <template> finirebbero con id duplicati).
    const fragment = this.templateTarget.content.cloneNode(true)
    const index = this.indexValue
    this.indexValue++
    fragment.querySelectorAll("[name]").forEach((el) => {
      el.name = el.name.replaceAll("__INDEX__", index)
    })
    fragment.querySelectorAll("[id]").forEach((el) => {
      el.id = el.id.replaceAll("__INDEX__", index)
    })
    this.listTarget.appendChild(fragment)
    this.refreshEmpty()
  }

  remove(event) {
    event.preventDefault()
    const row = event.target.closest("[data-column-row]")
    if (row) row.remove()
    this.refreshEmpty()
  }

  // Al cambio del tipo: mostra il campo "valori" solo per category; il ruolo segue syncRole().
  onKindChange(event) {
    const row = event.target.closest("[data-column-row]")
    if (!row) return
    const options = row.querySelector("[data-options]")
    if (options) options.hidden = event.target.value !== "category"
    this.syncRole(row)
  }

  // Una foto è sempre Input: se il kind CORRENTE della riga è photo, forza il valore e blocca la
  // option "target" (mai l'intero select). Legge il kind dalla riga (non dall'event) così vale
  // anche a connect() per le righe già kind=photo dal server.
  syncRole(row) {
    const kindSelect = row.querySelector('[data-test="datasets-column-kind"]')
    const role = row.querySelector('select[name$="[role]"]')
    if (!kindSelect || !role) return

    const targetOption = Array.from(role.options).find((option) => option.value === "target")
    if (kindSelect.value === "photo") {
      role.value = "input"
      if (targetOption) targetOption.disabled = true
    } else if (targetOption) {
      targetOption.disabled = false
    }
    role.dispatchEvent(new CustomEvent("ui--select:refresh"))
  }

  refreshEmpty() {
    if (this.hasEmptyTarget) this.emptyTarget.hidden = this.listTarget.children.length > 0
  }
}
