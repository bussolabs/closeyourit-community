import { Controller } from "@hotwired/stimulus"
import { cable } from "@hotwired/turbo-rails"

// Badge "N persone stanno guardando" (Task D2).
//
// Registra il viewer corrente sul ViewersChannel (per-risorsa, identificata dal gid passato come
// data-value) e applica i Turbo Stream di conteggio in arrivo: il badge HTML è reso server-side da
// Ui::BadgeComponent (partial member/viewers/_count) — qui non si costruisce markup, si renderizza il
// messaggio Turbo ricevuto sul canale. Un heartbeat periodico (`perform "touch"`) rinfresca il TTL
// lato server, così un viewer che resta sulla pagina non viene ripulito per scadenza.
//
// Riusa il consumer condiviso di turbo-rails (cable.getConsumer()), lo stesso dei turbo_stream_from.
// Il wrapper con questo controller NON è il target dei broadcast (lo è il <span id="viewers_<gid>">
// interno), quindi non viene mai sostituito → la subscription non si ricrea e non si conta due volte.
export default class extends Controller {
  static values = {
    resource: String,
    heartbeat: { type: Number, default: 20000 }
  }

  connect() {
    const lifecycle = {}
    this.lifecycle = lifecycle
    this.subscription = null

    cable
      .getConsumer()
      .then((consumer) => {
        if (this.lifecycle !== lifecycle) return
        this.subscription = consumer.subscriptions.create(
          { channel: "ViewersChannel", resource: this.resourceValue },
          {
            ...this.heartbeatCallbacks(lifecycle),
            received: (data) => { if (this.lifecycle === lifecycle) this.render(data) }
          }
        )
      })
      .catch(() => {})
  }

  heartbeatCallbacks(lifecycle) {
    const current = () => this.lifecycle === lifecycle
    return {
      connected: () => {
        if (!current()) return
        this.stopHeartbeat()
        this.timer = setInterval(() => this.subscription?.perform("touch"), this.heartbeatValue)
      },
      disconnected: () => { if (current()) this.stopHeartbeat() },
      rejected: () => { if (current()) this.stopHeartbeat() }
    }
  }

  stopHeartbeat() {
    if (this.timer) clearInterval(this.timer)
    this.timer = null
  }

  disconnect() {
    this.lifecycle = null
    this.stopHeartbeat()
    if (this.subscription) {
      this.subscription.unsubscribe()
      this.subscription = null
    }
  }

  // Il broadcast del canale è un <turbo-stream action="replace" target="viewers_<gid>">: lo applica
  // al DOM via Turbo (window.Turbo è impostato all'avvio di turbo-rails).
  render(data) {
    window.Turbo?.renderStreamMessage?.(data)
  }
}
