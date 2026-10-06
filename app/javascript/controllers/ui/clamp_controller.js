import { Controller } from "@hotwired/stimulus"

// CYRA-405 — un'analisi o un piano possono essere ottomila caratteri: aperti per intero seppelliscono
// tutto il resto della pagina. Qui il testo parte accorciato a una decina di righe, con un comando
// per vederlo tutto.
//
// Senza JS resta tutto visibile: il taglio lo mette il controller al connect, non il markup. Se il
// testo ci sta già dentro l'altezza, il comando non compare — un «mostra tutto» su tre righe è rumore.
export default class extends Controller {
  static targets = ["body", "toggle", "label"]
  static values = { max: { type: Number, default: 240 }, more: String, less: String }

  connect() {
    this.expanded = false
    // CYRA-1003 — in a hidden tab or a closed <details> nothing has a height yet: measure once it shows.
    if (this.bodyTarget.getClientRects().length === 0) {
      this.observer = new ResizeObserver(() => {
        if (this.bodyTarget.getClientRects().length === 0) return
        this.observer.disconnect()
        this.connect()
      })
      this.observer.observe(this.bodyTarget)
      return
    }
    if (this.bodyTarget.scrollHeight <= this.maxValue + 24) {
      this.toggleTarget.hidden = true
      return
    }
    this.collapse()
  }

  disconnect() {
    this.observer?.disconnect()
  }

  toggle() {
    this.expanded ? this.collapse() : this.expand()
  }

  collapse() {
    this.expanded = false
    this.bodyTarget.style.maxHeight = `${this.maxValue}px`
    this.bodyTarget.style.overflow = "hidden"
    this.bodyTarget.dataset.clamped = "true"
    this.labelTarget.textContent = this.moreValue
  }

  expand() {
    this.expanded = true
    this.bodyTarget.style.maxHeight = ""
    this.bodyTarget.style.overflow = ""
    this.bodyTarget.dataset.clamped = "false"
    this.labelTarget.textContent = this.lessValue
  }
}
