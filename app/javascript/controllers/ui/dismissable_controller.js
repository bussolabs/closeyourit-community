import { Controller } from "@hotwired/stimulus"

// Chiusura Esc + click-esterno per <details> di disclosure (dropdown menu semplici: user-menu,
// org switcher, ecc.) — MAI per <dialog> modali, che hanno già Esc/backdrop nativi via
// ui--dialog. L'apertura resta il <details>/<summary> nativo (funziona anche senza JS); questo
// controller aggiunge solo la chiusura come progressive enhancement:
//   - Escape mentre il focus è dentro il <details> aperto → chiude e riporta il focus al
//     <summary> (l'utente non perde il punto in cui era, niente focus-trap perso nel vuoto).
//   - Click fuori dal <details> aperto → chiude (nessun ritorno focus: l'utente ha già spostato
//     l'attenzione altrove).
// Un'istanza per elemento (Stimulus): più <details data-controller="ui--dismissable"> sulla
// stessa pagina sono indipendenti, ognuno coi propri listener rimossi in disconnect (no leak).
// Per il kebab di riga (che deve sfuggire all'overflow-x delle tabelle con position:fixed) resta
// dedicato ui--row-menu, che già implementa lo stesso pattern Esc/outside — non duplicarlo qui.
//
//   <details data-controller="ui--dismissable">
//     <summary>…</summary>
//     <div>…</div>
//   </details>
export default class extends Controller {
  connect() {
    this.onKeydown = (e) => {
      if (e.key !== "Escape" || !this.element.open) return
      if (!this.element.contains(document.activeElement)) return
      this.closeAndRefocus()
    }
    this.onClick = (e) => {
      if (this.element.open && !this.element.contains(e.target)) this.element.open = false
    }
    document.addEventListener("keydown", this.onKeydown)
    document.addEventListener("click", this.onClick)
  }

  disconnect() {
    document.removeEventListener("keydown", this.onKeydown)
    document.removeEventListener("click", this.onClick)
  }

  // Solo su Esc: chiude E riporta il focus al summary (l'utente non perde il punto in cui era).
  // Il click-esterno chiude senza rubare il focus a chi/dove l'utente ha appena cliccato.
  closeAndRefocus() {
    const summary = this.element.querySelector("summary")
    this.element.open = false
    if (summary) summary.focus()
  }
}
