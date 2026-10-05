import { Controller } from "@hotwired/stimulus"

// Rivela on-demand il valore in chiaro di un secret (CYRA-204): al click recupera il valore dall'endpoint
// reveal — che registra l'accesso — e lo mostra; un secondo click lo nasconde e lo rimuove dal DOM. Il
// valore NON è nel sorgente HTML. Gemello flat del pattern matrice del vault di progetto (CYRA-202).
//
// Uso: <div data-controller="secret-reveal" data-secret-reveal-url-value="/…/reveal">
//        <button data-action="secret-reveal#toggle" data-secret-reveal-target="toggle">Mostra</button>
//        <code data-secret-reveal-target="value" hidden></code>
//      </div>
export default class extends Controller {
  static targets = ["value", "toggle"]
  static values = { url: String, show: String, hide: String, error: String }

  // Il valore rivelato finisce nel DOM (textContent di <code>), che Turbo serializza nella snapshot di
  // navigazione: senza pulirlo, tornando "indietro" il valore riapparirebbe dallo snapshot senza passare
  // dall'endpoint reveal, quindi senza traccia. Lo rimuoviamo prima che Turbo faccia la cache.
  connect() {
    this.concealBeforeCache = () => this.conceal()
    document.addEventListener("turbo:before-cache", this.concealBeforeCache)
  }

  disconnect() {
    document.removeEventListener("turbo:before-cache", this.concealBeforeCache)
  }

  toggle(event) {
    event.preventDefault()
    if (this.revealed) {
      this.conceal()
    } else {
      this.reveal()
    }
  }

  async reveal() {
    // Ogni click ha un token: una risposta tardiva (già nascosto di nuovo) viene scartata.
    const token = (this.revealToken = (this.revealToken || 0) + 1)
    try {
      const response = await fetch(this.urlValue, {
        headers: { Accept: "application/json" },
        credentials: "same-origin"
      })
      if (!response.ok) throw new Error(`reveal failed: ${response.status}`)
      const data = await response.json()
      if (this.revealToken !== token) return
      this.valueTarget.textContent = data.value ?? ""
      this.valueTarget.hidden = false
      this.revealed = true
      if (this.hasToggleTarget && this.hasHideValue) this.toggleTarget.textContent = this.hideValue
    } catch {
      if (this.revealToken === token && this.hasErrorValue) {
        this.valueTarget.textContent = this.errorValue
        this.valueTarget.hidden = false
      }
    }
  }

  conceal() {
    // Rimuove il valore dal DOM: non deve restare leggibile dopo aver nascosto.
    this.revealToken = (this.revealToken || 0) + 1
    this.valueTarget.textContent = ""
    this.valueTarget.hidden = true
    this.revealed = false
    if (this.hasToggleTarget && this.hasShowValue) this.toggleTarget.textContent = this.showValue
  }
}
