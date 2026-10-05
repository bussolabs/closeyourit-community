import { Controller } from "@hotwired/stimulus"

// CYRA-481 — mostra soltanto i campi che valgono per l'evento scelto.
//
// I campi NON applicabili si nascondono con l'attributo [hidden], non si rimuovono dal DOM: un campo
// rimosso non verrebbe inviato e al salvataggio azzererebbe un valore gia scritto su una regola
// esistente (e il rischio dichiarato nel ticket). La matrice evento -> campi arriva dal server
// (Alerting::Rule.fields_matrix), la stessa fonte che decide lo stato iniziale: client e server non
// possono divergere.
export default class extends Controller {
  static targets = ["event", "field"]
  static values = { matrix: Object }

  connect() {
    this.refresh()
  }

  refresh() {
    const allowed = this.matrixValue[this.eventTarget.value] || []
    this.fieldTargets.forEach((field) => {
      field.hidden = !allowed.includes(field.dataset.field)
    })
  }
}
