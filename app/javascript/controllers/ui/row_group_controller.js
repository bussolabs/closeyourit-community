import { Controller } from "@hotwired/stimulus"

// CYRA-592 — apre e chiude un gruppo di righe dentro una tabella. Serve alla plancia delle
// approvazioni, dove centodieci righe si leggono come diciassette progetti: chiudere quelli che non
// interessano è l'unico modo per far stare la propria manciata di righe in uno schermo.
//
// Nasce qui e non con <details> perché dentro una tabella non c'è modo di avvolgere un gruppo di
// <tr>: <details> vuole un contenitore, e un contenitore in mezzo a <tbody> spezza le colonne — che
// è esattamente ciò che questa pagina non può permettersi, visto che la sua lettura verticale
// dipende dall'allineamento.
//
// Senza JS resta tutto aperto: la plancia si legge lo stesso, semplicemente non si richiude.
export default class extends Controller {
  static targets = ["row"]

  toggle(event) {
    const bottone = event.currentTarget
    const chiuso = bottone.getAttribute("aria-expanded") === "false"

    bottone.setAttribute("aria-expanded", chiuso ? "true" : "false")
    // Il chevron gira insieme al gruppo: senza, l'unico segno di un gruppo chiuso sarebbe l'assenza
    // delle righe, che a metà tabella si legge come «questo progetto non ne ha».
    bottone.querySelector("[data-row-group-chevron]")?.classList.toggle("-rotate-90", !chiuso)

    this.rowTargets
      .filter((riga) => riga.dataset.rowGroupKey === event.params.key)
      .forEach((riga) => { riga.hidden = !chiuso })
  }
}
