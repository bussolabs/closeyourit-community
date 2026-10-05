import { Controller } from "@hotwired/stimulus"

// Aggiorna soltanto stato e risultato. Una richiesta alla volta, nessuna su una scheda nascosta.
export default class extends Controller {
  static values = { active: Boolean, url: String, interval: { type: Number, default: 3000 } }

  connect() {
    this.connected = true
    this.schedule()
  }

  disconnect() {
    this.connected = false
    if (this.timer) clearTimeout(this.timer)
  }

  schedule() {
    if (this.connected && this.activeValue) this.timer = setTimeout(() => this.refresh(), this.intervalValue)
  }

  async refresh() {
    const frame = this.element.closest("turbo-frame")
    if (!frame || document.hidden) return this.schedule()

    try {
      if (frame.src) frame.reload()
      else frame.src = this.urlValue
      await frame.loaded
    } catch {
      // Turbo segnala l'errore; il prossimo intervallo recupera anche senza eventi realtime.
    } finally {
      // Il render riuscito riconnette un controller nuovo; quello precedente resta disconnesso.
      // Su errore di rete resta invece qui e riprova senza richieste sovrapposte.
      this.schedule()
    }
  }
}
