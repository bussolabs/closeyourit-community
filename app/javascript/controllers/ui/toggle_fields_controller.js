import { Controller } from "@hotwired/stimulus"

// Nasconde/disabilita i campi "field" quando la checkbox collegata è attiva
// (es. opzione "l'utente imposta la propria password" → nasconde i campi password).
export default class extends Controller {
  static targets = ["field"]

  toggle(event) {
    const hide = event.target.checked
    this.fieldTargets.forEach((field) => {
      field.hidden = hide
      field.querySelectorAll("input, select, textarea").forEach((input) => { input.disabled = hide })
    })
  }
}
