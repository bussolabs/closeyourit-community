import { Controller } from "@hotwired/stimulus"

// Mostra solo i campi pertinenti al tipo di check selezionato (CYRA-151): url per http, host/porta per
// i check non-web. Progressive enhancement: senza JS tutti i campi restano visibili e la validazione
// server-side (condizionale sul check_type) resta l'unica autorità sulla correttezza.
export default class extends Controller {
  static targets = ["field"]

  connect() {
    this.update()
  }

  update() {
    const select = this.element.querySelector("select[name='check_type']")
    const type = select ? select.value : "http"
    this.fieldTargets.forEach((el) => {
      const types = (el.dataset.checkTypes || "").split(" ")
      el.hidden = !types.includes(type)
    })
  }
}
