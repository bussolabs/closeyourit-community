import { Controller } from "@hotwired/stimulus"
import { cable } from "@hotwired/turbo-rails"

// Indicatore di stato della connessione Action Cable nell'header member.
//
// Non apre un canale dedicato: riusa il consumer condiviso di turbo-rails
// (cable.getConsumer()) — lo stesso che alimenta tutti i turbo_stream_from —
// e ne legge lo stato del WebSocket via connection.getState() ("open" |
// "connecting" | "closing" | "closed" | null). Aggiorna SOLO le classi colore
// del box + del pallino e il testo del label, senza ricaricare la pagina.
//
// It drives the dot and the label inside the presence control. Turbo can replace both
// together with the list: the *TargetConnected callbacks reapply the current state at once.
//
// Visual states (CYRA-898):
//   connected               -> green dot, label for screen readers only
//   connecting/disconnected -> amber pulsing dot (motion-safe), visible label
//   offline                 -> grey dot, visible label
const PULSE = "motion-safe:animate-pulse"

const DOT_COLOR = {
  connected: "bg-green-500",
  reconnecting: "bg-amber-500",
  offline: "bg-gray-400"
}
const ALL_DOT_COLORS = Object.values(DOT_COLOR)

const LABEL_COLOR = {
  reconnecting: "text-amber-700 dark:text-amber-300",
  offline: "text-gray-600 dark:text-zinc-400"
}
const ALL_LABEL_COLORS = Object.values(LABEL_COLOR).flatMap((color) => color.split(" "))

export default class extends Controller {
  static targets = ["icon", "text"]
  static values = {
    connectedLabel: String,
    reconnectingLabel: String,
    offlineLabel: String,
    debug: { type: Boolean, default: false },
    interval: { type: Number, default: 2000 }
  }

  connect() {
    this.state = null

    this.onNetwork = () => this.refresh()
    window.addEventListener("online", this.onNetwork)
    window.addEventListener("offline", this.onNetwork)

    cable
      .getConsumer()
      .then((consumer) => {
        this.consumer = consumer
        this.timer = setInterval(() => this.refresh(), this.intervalValue)
        this.refresh()
      })
      .catch((error) => {
        this.log("consumer non disponibile", error)
        this.apply("offline")
      })
  }

  iconTargetConnected(icon) {
    this.renderIcon(icon, this.state || "connected")
  }

  textTargetConnected(text) {
    this.renderText(text, this.state || "connected")
  }

  disconnect() {
    if (this.timer) clearInterval(this.timer)
    window.removeEventListener("online", this.onNetwork)
    window.removeEventListener("offline", this.onNetwork)
  }

  refresh() {
    let next

    if (typeof navigator !== "undefined" && navigator.onLine === false) {
      next = "offline"
    } else {
      const cableState = this.consumer?.connection?.getState?.() ?? null
      next = cableState === "open" ? "connected" : "reconnecting"
    }

    this.apply(next)
  }

  apply(state) {
    if (state === this.state) return
    this.state = state
    this.log(`stato connessione -> ${state}`)

    if (this.hasIconTarget) this.renderIcon(this.iconTarget, state)

    if (this.hasTextTarget) this.renderText(this.textTarget, state)
  }

  renderIcon(icon, state) {
    icon.classList.remove(...ALL_DOT_COLORS, PULSE)
    icon.classList.add(DOT_COLOR[state])
    if (state === "reconnecting") icon.classList.add(PULSE)
  }

  renderText(text, state) {
    text.textContent = this.labelFor(state)
    text.classList.remove(...ALL_LABEL_COLORS)
    text.classList.toggle("sr-only", state === "connected")
    if (LABEL_COLOR[state]) text.classList.add(...LABEL_COLOR[state].split(" "))
  }

  labelFor(state) {
    if (state === "connected") return this.connectedLabelValue
    if (state === "offline") return this.offlineLabelValue
    return this.reconnectingLabelValue
  }

  log(...args) {
    if (this.debugValue) console.debug("[connection-status]", ...args)
  }
}
