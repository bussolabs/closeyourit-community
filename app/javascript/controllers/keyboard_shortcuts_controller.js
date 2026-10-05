import { Controller } from "@hotwired/stimulus"

// Tasti di TRIAGE del dettaglio errore: r/i/p submettono i form resolve/ignore/promote (progressive
// enhancement — i button_to funzionano anche senza JS; il turbo_confirm su promote scatta comunque).
// L'help "?" e il suo modale sono ora GLOBALI e CONDIVISI (controller `keyboard`, CYRA-28): questa
// pagina si limita a dichiarare i propri binding nel registry via [data-keyboard-doc]. Guard identici
// al controller globale: ignora i modifier e la digitazione in campi editabili.
export default class extends Controller {
  connect() {
    this._onKeydown = this.handle.bind(this)
    window.addEventListener("keydown", this._onKeydown)
  }

  disconnect() {
    window.removeEventListener("keydown", this._onKeydown)
  }

  handle(event) {
    if (event.metaKey || event.ctrlKey || event.altKey) return
    if (this.#typing(event.target)) return

    switch (event.key) {
      case "r": this.#submit("triage-resolve"); break
      case "i": this.#submit("triage-ignore"); break
      case "p": this.#submit("promote-ticket"); break
      default: return
    }
  }

  #submit(testId) {
    const button = this.element.querySelector(`[data-test="${testId}"]`)
    button?.closest("form")?.requestSubmit()
  }

  #typing(el) {
    if (!el) return false
    return [ "INPUT", "TEXTAREA", "SELECT" ].includes(el.tagName) || el.isContentEditable
  }
}
