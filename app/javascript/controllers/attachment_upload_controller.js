import { Controller } from "@hotwired/stimulus"

// Dropzone allegati ticket (progressive enhancement).
// - change sull'input file → mostra i nomi selezionati e AUTO-SUBMITTA il form.
// - drag&drop sul label → popola l'input via DataTransfer e submitta.
// - durante il submit: bottone disabilitato + stato "Caricamento…".
// Senza JS l'input resta usabile e il bottone "Aggiungi" submitta (fallback no-JS).
export default class extends Controller {
  // zone: optional drop area to highlight, when the controller wraps more than the form (CYRA-883).
  static targets = ["input", "status", "submit", "zone"]
  static values = { selected: String, uploading: String }

  change() {
    if (this.inputTarget.files.length === 0) return // dialog annullato
    this.renderFilenames()
    this.submitForm()
  }

  renderFilenames() {
    if (!this.hasStatusTarget) return
    const names = Array.from(this.inputTarget.files).map((file) => file.name)
    // textContent (non innerHTML): i nomi file sono dati utente → anti-XSS.
    this.statusTarget.textContent = `${this.selectedValue} ${names.join(", ")}`
    this.statusTarget.hidden = false
  }

  submitForm() {
    if (this.hasStatusTarget) this.statusTarget.textContent = this.uploadingValue
    if (this.hasSubmitTarget) this.submitTarget.disabled = true // mai disabilitare l'input: perderebbe files[]
    // The input's own form: the controller may sit on a wrapper around it (CYRA-883).
    const form = this.inputTarget.form || this.element
    form.requestSubmit() // redirect post-create → Turbo ricarica, lo stato si azzera
  }

  // --- drag & drop sul label ---
  dragover(event) {
    event.preventDefault()
    event.dataTransfer.dropEffect = "copy"
    this.dropArea.classList.add("ring-2", "ring-indigo-200", "dark:ring-indigo-500/40")
  }

  dragleave() {
    this.dropArea.classList.remove("ring-2", "ring-indigo-200", "dark:ring-indigo-500/40")
  }

  drop(event) {
    event.preventDefault()
    this.dropArea.classList.remove("ring-2", "ring-indigo-200", "dark:ring-indigo-500/40")
    const dropped = event.dataTransfer.files
    if (!dropped || dropped.length === 0) return
    const data = new DataTransfer()
    Array.from(dropped).forEach((file) => data.items.add(file))
    this.inputTarget.files = data.files
    this.change()
  }

  get dropArea() {
    return this.hasZoneTarget ? this.zoneTarget : this.element
  }
}
