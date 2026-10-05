import { Controller } from "@hotwired/stimulus"

// Copia il testo di un target `source` negli appunti, con feedback breve sul label del bottone.
// Uso: <div data-controller="clipboard" data-clipboard-copied-value="Copied">
//        <code data-clipboard-target="source">…</code>
//        <button data-action="clipboard#copy"><span data-clipboard-target="label">Copy</span></button>
//      </div>
//
// CYRA-202: per i secret il valore NON è nel DOM (chi apre il sorgente lo leggerebbe). Con
// `data-clipboard-url-value` il valore è recuperato on-demand da un endpoint che registra l'accesso,
// invece di leggerlo dal target `source`. Senza urlValue il comportamento resta identico (source target).
export default class extends Controller {
  static targets = ["source", "label"]
  static values = {
    copied: { type: String, default: "Copied" },
    error: { type: String, default: "Error" },
    url: String
  }

  copy(event) {
    event.preventDefault()
    if (this.hasUrlValue && this.urlValue) {
      this.copyFromUrl()
    } else if (this.hasSourceTarget) {
      navigator.clipboard.writeText(this.sourceTarget.textContent.trim())
        .then(() => this.flash(this.copiedValue))
        .catch(() => this.flash(this.errorValue))
    }
  }

  // Recupera il valore dall'endpoint e lo copia. `navigator.clipboard.write` con un ClipboardItem la cui
  // parte è una Promise<Blob> è invocata SINCRONA nel gesture: preserva la transient user activation, che
  // Safari (e talora Firefox) richiedono — dopo un `await fetch` la writeText verrebbe rifiutata. Se il
  // fetch fallisce nulla finisce negli appunti e il feedback segnala l'errore (mai un incolla silenzioso
  // del contenuto precedente). Fallback a fetch+writeText dove ClipboardItem non è supportato.
  copyFromUrl() {
    const text = this.fetchValue()
    if (typeof ClipboardItem === "function" && navigator.clipboard?.write) {
      const blob = text.then((value) => new Blob([value], { type: "text/plain" }))
      navigator.clipboard.write([new ClipboardItem({ "text/plain": blob })])
        .then(() => this.flash(this.copiedValue))
        .catch(() => this.flash(this.errorValue))
    } else {
      text
        .then((value) => navigator.clipboard.writeText(value))
        .then(() => this.flash(this.copiedValue))
        .catch(() => this.flash(this.errorValue))
    }
  }

  async fetchValue() {
    const response = await fetch(this.urlValue, {
      headers: { Accept: "application/json" },
      credentials: "same-origin"
    })
    if (!response.ok) throw new Error(`reveal failed: ${response.status}`)
    const data = await response.json()
    return data.value ?? ""
  }

  flash(message) {
    if (!this.hasLabelTarget) return
    const original = this.labelTarget.textContent
    this.labelTarget.textContent = message
    setTimeout(() => { this.labelTarget.textContent = original }, 1500)
  }
}
