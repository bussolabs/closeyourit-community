import { Controller } from "@hotwired/stimulus"

// Schema permessi effettivi (what-if): ad ogni change nel form collegato (ruoli/scope/override del
// membro, oppure membri/ruoli/scope del team) ricalcola lato server i permessi PENDENTI e rimpiazza il
// contenuto dello schema. Nessun templating in JS: il server rende il partial member/shared/_access_matrix
// → niente drift col Resolver. Progressive enhancement: senza JS resta lo stato salvato (render server-side).
export default class extends Controller {
  static targets = ["schema"]
  static values = { url: String, form: String, debounce: { type: Number, default: 300 } }

  connect() {
    this.form = document.getElementById(this.formValue)
    if (!this.form) return
    this.onChange = this.onChange.bind(this)
    this.form.addEventListener("change", this.onChange)
  }

  disconnect() {
    if (this.form) this.form.removeEventListener("change", this.onChange)
    clearTimeout(this.timer)
  }

  onChange() {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.refresh(), this.debounceValue)
  }

  async refresh() {
    if (!this.hasSchemaTarget) return
    const token = document.querySelector('meta[name="csrf-token"]')?.content
    try {
      const response = await fetch(this.urlValue, {
        method: "POST",
        headers: { "X-CSRF-Token": token || "", Accept: "text/html" },
        body: new FormData(this.form),
      })
      if (!response.ok) return
      this.schemaTarget.innerHTML = await response.text()
    } catch (_error) {
      // silenzioso: lo schema resta sull'ultimo stato valido
    }
  }
}
