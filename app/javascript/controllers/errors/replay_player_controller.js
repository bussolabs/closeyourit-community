import { Controller } from "@hotwired/stimulus"

// Player session replay: scarica gli eventi rrweb dell'occorrenza (lazy, la prima volta che è a
// schermo) e monta rrweb-player nel target. Un solo fetch per pannello (guard `loaded`), retry alla
// visibilità successiva se va in errore. Il testo di stato arriva via values (i18n server-side). Registrato automaticamente
// come `errors--replay-player` (eagerLoadControllersFrom su app/javascript/controllers).
// The frame is always this tall, phone or desktop recording: only its width follows the recording.
const FRAME_HEIGHT = 420
// Below this the player's own controls no longer fit.
const MIN_WIDTH = 320
const META_EVENT = 4

export default class extends Controller {
  static targets = ["status", "mount"]
  static values = { url: String, loading: String, error: String, empty: String }

  connect() {
    this.loaded = false
    this.player = null
    // The player may sit in a closed tab or in the panels of an occurrence not selected: it loads
    // the first time it is really on screen (no fetch for a replay nobody looks at).
    this.observer = new IntersectionObserver((entries) => {
      if (entries.some((entry) => entry.isIntersecting)) this.#load()
    })
    this.observer.observe(this.element)
  }

  disconnect() {
    this.observer?.disconnect()
    this.player = null
  }

  async #load() {
    if (this.loaded) return
    this.loaded = true
    this.#status(this.loadingValue)
    try {
      const response = await fetch(this.urlValue, { headers: { Accept: "application/json" } })
      if (!response.ok) throw new Error(`HTTP ${response.status}`)
      const body = await response.json()
      const events = body?.data?.events ?? []
      // rrweb-player richiede almeno un full snapshot + un evento per rendere qualcosa.
      if (events.length < 2) {
        this.#status(this.emptyValue)
        return
      }
      await this.#mount(events)
      this.#status("")
    } catch {
      this.loaded = false // allows a retry the next time it comes on screen
      this.#status(this.errorValue)
    }
  }

  // Import DINAMICO di rrweb-player (vendorizzato: vendor/javascript/rrweb-player.js, CSS in
  // app/assets/stylesheets/rrweb-player.css caricato via yield :head nella show). Dinamico così il
  // controller resta caricabile anche se il pin manca (degrada a "non disponibile" senza rompere il
  // resto del JS del Monitor).
  async #mount(events) {
    const { default: rrwebPlayer } = await import("rrweb-player")
    this.player = new rrwebPlayer({
      target: this.mountTarget,
      props: {
        events,
        autoPlay: false,
        showController: true,
        width: this.#frameWidth(events),
        height: FRAME_HEIGHT,
      },
    })
  }

  // The recorded viewport (rrweb Meta event) gives the proportions; the panel caps the width.
  #frameWidth(events) {
    const viewport = events.find((event) => event.type === META_EVENT)?.data
    const ratio = viewport?.width && viewport?.height ? viewport.width / viewport.height : 16 / 9
    const available = this.mountTarget.clientWidth || 800
    return Math.round(Math.min(available, Math.max(MIN_WIDTH, FRAME_HEIGHT * ratio)))
  }

  #status(text) {
    if (this.hasStatusTarget) this.statusTarget.textContent = text
  }
}
