import { Controller } from "@hotwired/stimulus"

// Modale basato sull'elemento <dialog> nativo: showModal() fornisce focus-trap, Esc e
// backdrop senza JS custom. open/close via data-action; click sul backdrop chiude.
//
//   <div data-controller="ui--dialog">
//     <button data-action="ui--dialog#open">Apri</button>
//     <dialog data-ui--dialog-target="dialog" data-action="click->ui--dialog#backdrop">…</dialog>
//   </div>
export default class extends Controller {
  static targets = ["dialog"]
  // open: apre il dialog al connect (es. re-render server con errore su questo esito) così
  // l'utente ritrova il dialog aperto invece di vederlo sparire con un toast ignorabile.
  static values = { open: Boolean }

  connect() {
    if (this.openValue) this.open()
  }

  // A remote trigger names the dialog by id (data-ui--dialog-dialog-param): it lives outside this
  // element, e.g. one dialog per version next to a ⋯ menu that holds every version.
  open(event) {
    const id = event?.params?.dialog
    const dialog = id ? document.getElementById(id) : this.dialogTarget
    dialog?.showModal()
  }

  close() {
    this.dialogTarget.close()
  }

  // Chiude se il click cade sul <dialog> stesso (area backdrop), non sul contenuto interno.
  backdrop(event) {
    if (event.target === this.dialogTarget) this.dialogTarget.close()
  }
}
