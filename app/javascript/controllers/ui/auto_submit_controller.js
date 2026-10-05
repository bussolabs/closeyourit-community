import { Controller } from "@hotwired/stimulus"

// CYRA-500 — una barra di filtri in cui alcuni controlli si applicano al clic e altri aspettano un
// bottone insegna due gesti diversi per la stessa cosa: si sceglie il progetto e non succede niente,
// finché non ci si accorge dell'Apply in fondo. Qui il form GET si invia da solo al cambio di un
// campo, e il bottone resta come riserva per chi non ha JS (nascosto al connect, come filter-bar).
//
// requestSubmit, non submit(): la GET passa da Turbo Drive e la pagina non ricarica per intero.
export default class extends Controller {
  connect() {
    this.fallback = this.element.querySelector("button[type=submit]")
    if (this.fallback) this.fallback.hidden = true
  }

  submit() {
    this.element.requestSubmit()
  }
}
