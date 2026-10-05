import { Controller } from "@hotwired/stimulus"

// Fallback di riconciliazione dello streaming dell'assistente. Il pannello riceve la risposta via
// broadcast Turbo, ma se sottoscrive lo stream DOPO che il job ha già inviato il broadcast finale
// (rete/caricamento lenti), quel messaggio va perso e la bolla resterebbe su "sto scrivendo". Questo
// controller interroga lo stato reale dal server e, appena il messaggio è finalizzato (complete/failed),
// sostituisce la bolla — garantendo la consistenza a prescindere dai broadcast persi. Non tocca il DOM
// finché lo stato resta "streaming", così non cancella i delta già arrivati durante lo streaming normale.
export default class extends Controller {
  static values = {
    url: String,
    delay: { type: Number, default: 4000 },
    interval: { type: Number, default: 3000 },
  }

  connect() {
    // Parte in ritardo: nel caso normale il broadcast finale arriva prima e rimpiazza la bolla
    // (disconnettendo questo controller), così non si interroga affatto il server.
    this.timer = setTimeout(() => this.poll(), this.delayValue)
  }

  disconnect() {
    this.stopped = true
    clearTimeout(this.timer)
  }

  async poll() {
    if (this.stopped) return

    try {
      const response = await fetch(this.urlValue, { headers: { Accept: "text/html" } })
      if (response.ok) {
        const html = await response.text()
        const fresh = new DOMParser().parseFromString(html, "text/html").querySelector("[data-status]")
        // Contenuto server-rendered e già sanitizzato (assistant_message_html escapa il testo del modello
        // e linka solo rotte del catalogo). Quando è finalizzato sostituisce il NODO parsato via
        // replaceWith — non `innerHTML`/`outerHTML =`, così non si introduce un sink XSS da stringa.
        // A spoken message stays "transcribing" until Whisper answers: keep polling (CYRA-908).
        if (fresh && !["streaming", "transcribing"].includes(fresh.dataset.status)) {
          this.element.replaceWith(fresh)
          return
        }
      }
    } catch (_error) {
      // errore di rete transitorio: ritenta al prossimo tick
    }

    this.timer = setTimeout(() => this.poll(), this.intervalValue)
  }
}
