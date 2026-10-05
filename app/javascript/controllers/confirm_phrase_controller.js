import { Controller } from "@hotwired/stimulus"

// CYRA-469 — la revoca di un codice di accesso è l'azione dal raggio più ampio del prodotto: non
// deve riuscire con un clic distratto. Il pulsante resta spento finché non hai DIGITATO il nome
// esatto del codice. È solo progressive enhancement: la garanzia vera è lato server (il controller
// rifiuta la revoca senza la conferma esatta), qui si evita solo il clic a vuoto.
export default class extends Controller {
  static targets = ["input", "submit"]
  static values = { phrase: String }

  connect() {
    this.check()
  }

  check() {
    this.submitTarget.disabled = this.inputTarget.value.trim() !== this.phraseValue
  }
}
