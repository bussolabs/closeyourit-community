import { Controller } from "@hotwired/stimulus"

// Precompila la textarea del messaggio col testo standard dello step selezionato, finché l'utente non
// l'ha modificata a mano (progressive enhancement). Ogni <option> porta il default in data-body.
//
//   <select data-incident-update-target="phase" data-action="change->incident-update#fill">
//     <option value="detected" data-body="…">…</option>
//   </select>
//   <textarea data-incident-update-target="body">…</textarea>
export default class extends Controller {
  static targets = ["phase", "body"]

  connect() {
    this.pristine = true
    this.bodyTarget.addEventListener("input", () => { this.pristine = false })
    this.fill()
  }

  fill() {
    if (!this.pristine) return
    const option = this.phaseTarget.selectedOptions[0]
    if (option && option.dataset.body) this.bodyTarget.value = option.dataset.body
  }
}
