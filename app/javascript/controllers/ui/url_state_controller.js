import { Controller } from "@hotwired/stimulus"

// CYRA-817 — riallinea all'indirizzo corrente, un attimo prima dell'invio, i campi nascosti che
// portano nel form lo stato di un'ALTRA lista della stessa pagina (a che pagina è, cosa ci si sta
// cercando dentro).
//
// PERCHÉ SERVE: una lista dentro un turbo-frame si aggiorna senza che il resto della pagina venga
// ridisegnato. La barra dei filtri che sta FUORI dal frame resta quindi quella del primo
// caricamento, e i suoi campi nascosti invecchiano: chi poi filtra da lì rimanda indietro uno stato
// vecchio e l'altra lista torna a pagina uno. Il server non può accorgersene — quella barra non
// gliel'ha più chiesta nessuno.
//
// Un campo che resta senza valore si DISABILITA invece di viaggiare vuoto: un parametro vuoto
// nell'indirizzo è rumore, e per i filtri ricordati «presente e vuoto» non vuol dire «assente».
//
// Valori scalari soltanto: un filtro multi-valore è più campi con lo stesso nome, e chi ne ha
// bisogno lo passa in `hidden:` (il server lo rende per intero, ed è giusto così quando la barra
// viene ridisegnata a ogni navigazione).
export default class extends Controller {
  static targets = ["field"]

  sync() {
    const params = new URLSearchParams(window.location.search)
    this.fieldTargets.forEach((field) => {
      field.value = params.get(field.dataset.urlStateParam) || ""
      field.disabled = field.value === ""
    })
  }
}
