import { Controller } from "@hotwired/stimulus"
import { Turbo, cable } from "@hotwired/turbo-rails"

// Presenza "chi è online" nell'header member.
//
// Riusa il consumer condiviso di turbo-rails (cable.getConsumer()) — lo stesso WebSocket che
// alimenta tutti i turbo_stream_from — e apre una subscription a PresenceChannel. Questa
// subscription è il "beacon": il suo subscribe/unsubscribe lato server registra/rimuove
// l'appearance (multi-tab: una subscription per tab). NON passiamo alcun org id dal client:
// l'organizzazione è risolta server-side dalla connection (anti-BOLA).
//
// Aggiornamento DOM:
//  - steady-state: lo fa Turbo (broadcast_replace su #presence_list) — già sottoscritto nel layout.
//  - snapshot al join: PresenceChannel ci `transmit`a { type: "snapshot", stream } con un
//    <turbo-stream> già pronto, applicato qui via Turbo.renderStreamMessage (lo stesso renderer
//    sanzionato usato per tutti i broadcast: nessuna injection manuale di HTML). Necessario
//    quando il set online non cambia (es. seconda tab dello stesso utente) o per battere la race
//    di conferma di turbo_stream_from.
//
// Heartbeat: `perform("heartbeat")` entro il TTL dello store così l'account resta online e i
// ghost scaduti vengono ripuliti. L'intervallo è < TTL server (default 20s vs 45s).
export default class extends Controller {
  static values = {
    heartbeat: { type: Number, default: 20000 },
    debug: { type: Boolean, default: false }
  }

  connect() {
    const lifecycle = {}
    this.lifecycle = lifecycle
    cable
      .getConsumer()
      .then((consumer) => {
        if (this.lifecycle !== lifecycle) return
        this.subscription = consumer.subscriptions.create("PresenceChannel", {
          ...this.heartbeatCallbacks(lifecycle),
          received: (data) => { if (this.lifecycle === lifecycle) this.received(data) }
        })
      })
      .catch((error) => this.log("consumer non disponibile", error))
  }

  heartbeatCallbacks(lifecycle) {
    const current = () => this.lifecycle === lifecycle
    return {
      connected: () => {
        if (!current()) return
        this.stopHeartbeat()
        this.timer = setInterval(() => this.subscription?.perform("heartbeat"), this.heartbeatValue)
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

  received(data) {
    if (!data || data.type !== "snapshot" || typeof data.stream !== "string") return

    Turbo.renderStreamMessage(data.stream)
    this.log("snapshot applicato")
  }

  log(...args) {
    if (this.debugValue) console.debug("[presence]", ...args)
  }
}
