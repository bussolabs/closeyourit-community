import { Controller } from "@hotwired/stimulus"

// Prefill del template "decisione" nel form Knowledge: al passaggio del kind su `decision`,
// se il body è VUOTO viene riempito con lo scheletro Contesto/Decisione/Conseguenze (i18n,
// passato via value). Mai sovrascrivere testo esistente; gli altri kind non toccano nulla.
export default class extends Controller {
  static targets = ["body"]
  static values = { body: String }

  kindChanged(event) {
    if (event.target.value !== "decision") return
    if (this.bodyTarget.value.trim() !== "") return

    this.bodyTarget.value = this.bodyValue
    // Scrivere .value non emette `input`: senza questo il contatore caratteri (char-counter) resta
    // a zero dopo il prefill.
    this.bodyTarget.dispatchEvent(new Event("input", { bubbles: true }))
  }
}
