import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

// Un pezzo di pagina che si ricarica da solo quando il server dice che è vecchio (CYRA-823 per la
// scheda di un agente, CYRA-824 per quella di un sito osservato).
//
// Il server manda un SEGNALE senza contenuto (<turbo-stream action="refresh_frame" target="...">):
// non può mandare HTML, perché due persone davanti alla stessa pagina hanno permessi e visibilità
// diversi e una pagina renderizzata dal mittente non saprebbe per chi è. Qui il segnale diventa una
// richiesta del frame fatta con la sessione di chi guarda — quindi già filtrata — e il resto della
// pagina non si muove.
//
// L'azione è registrata all'import, una volta per tutta l'applicazione: le StreamActions sono
// globali, e il primo segnale può arrivare prima che un controller sia connesso. Vive QUI e in un
// posto solo: registrarla anche in un secondo file significherebbe due implementazioni che possono
// divergere, con l'ultima importata a vincere.
export const STALE_EVENT = "live-frame:stale"

Turbo.StreamActions.refresh_frame = function () {
  const frame = document.getElementById(this.getAttribute("target"))
  // Nessun frame con quel nome: chi guarda è su un'altra pagina. Non è un errore, è il caso normale.
  if (frame) frame.dispatchEvent(new CustomEvent(STALE_EVENT, { bubbles: true }))
}

export default class extends Controller {
  static values = { frame: String, url: String, interval: { type: Number, default: 60000 } }

  connect() {
    this.stale = false
    this.loading = false

    this.onStale = () => this.markStale()
    // Scheda tornata davanti, o rete tornata: i segnali persi mentre eravamo nascosti o scollegati
    // non tornano indietro, quindi al ritorno si riconcilia comunque, una volta.
    this.onVisible = () => this.markStale()
    this.onOnline = () => this.markStale()

    document.addEventListener(STALE_EVENT, this.onStale)
    document.addEventListener("visibilitychange", this.onVisible)
    window.addEventListener("online", this.onOnline)

    // Il battito d'ala che i segnali non possono dare. Parte di quello che la pagina dice non nasce
    // da un evento ma dal TEMPO che passa senza eventi: una macchina che muore smette di battere e
    // un controllo interrotto a metà resta «in corso» per sempre, quindi smettono anche di far
    // partire segnali. Copre anche il segnale perso per una disconnessione che nessun evento del
    // browser ha raccontato. Solo a scheda visibile: `drain` esce da sé quando è nascosta.
    this.timer = setInterval(() => this.markStale(), this.intervalValue)
  }

  disconnect() {
    document.removeEventListener(STALE_EVENT, this.onStale)
    document.removeEventListener("visibilitychange", this.onVisible)
    window.removeEventListener("online", this.onOnline)
    clearInterval(this.timer)
  }

  get frame() {
    return document.getElementById(this.frameValue)
  }

  markStale() {
    this.stale = true
    this.drain()
  }

  // Il debito si salda solo quando ha senso: mai a scheda nascosta (nessuno la sta guardando), mai
  // sovrapponendo due richieste. Quello che resta in sospeso viene ripreso al ritorno, non perso.
  async drain() {
    if (!this.stale || this.loading || document.hidden) return

    const frame = this.frame
    if (!frame) return

    this.stale = false
    this.loading = true
    let ancora = false
    try {
      // Il frame nasce SENZA `src`: il suo contenuto arriva già con la pagina, quindi all'apertura
      // non parte una seconda richiesta a vuoto. Da qui in poi l'indirizzo resta e si ricarica.
      if (frame.src) frame.reload()
      else frame.src = this.urlValue
      await frame.loaded
      ancora = this.stale // è arrivato un altro segnale mentre questa richiesta era in volo
    } catch {
      // Turbo segnala l'errore per conto suo. Si riprova al prossimo segnale o al ritorno della
      // scheda in primo piano: ritentare subito vorrebbe dire martellare un server che ha appena
      // fallito, e la pagina intanto continua a mostrare l'ultimo stato buono.
      this.stale = true
    } finally {
      this.loading = false
    }
    if (ancora) this.drain()
  }
}
