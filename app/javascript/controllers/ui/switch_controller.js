import { Controller } from "@hotwired/stimulus"

// Switch (toggle) con auto-save senza reload. Il toggle è ottimistico: aggiorna
// subito la UI, poi PATCH su urlValue con { [paramValue]: "1"/"0" }. Su risposta
// non-2xx (o errore di rete) reverte lo stato visivo. Senza JS il bottone è inerte:
// la persistenza è coperta dal request spec (rack_test non esegue Stimulus).
//
// CYRA-563 — il controller sta sulla riga, non sulla pill (`pill` è un target): accanto allo
// switch c'è l'etichetta che dichiara «si applica subito», e Stimulus trova i target solo dentro
// il proprio elemento. Dopo il PATCH l'etichetta conferma: «salvato» sparisce da sé, «non salvato»
// resta — prima il revert era muto e l'interruttore tornava indietro senza dire perché.
const STATUS_TONES = {
  idle: "text-gray-400 dark:text-zinc-500",
  saved: "text-emerald-600 dark:text-emerald-400",
  failed: "text-red-600 dark:text-red-400"
}

const SAVED_MS = 2500

export default class extends Controller {
  static targets = ["knob", "pill", "status"]
  static values = {
    url: String,
    param: String,
    checked: Boolean,
    immediateLabel: String,
    savedLabel: String,
    failedLabel: String
  }

  disconnect() {
    clearTimeout(this.statusTimer)
  }

  toggle() {
    if (this.saving) return
    const next = !this.checkedValue
    this.render(next)
    this.saving = true
    this.pillTarget.disabled = true
    fetch(this.urlValue, {
      method: "PATCH",
      credentials: "same-origin",
      headers: {
        "X-CSRF-Token": this.csrf,
        Accept: "application/json",
        "Content-Type": "application/json"
      },
      body: JSON.stringify({ [this.paramValue]: next ? "1" : "0" })
    })
      .then((response) => {
        if (response.ok) this.status(this.savedLabelValue, "saved", SAVED_MS)
        else this.fail(next)
      })
      .catch(() => this.fail(next))
      .finally(() => { this.saving = false; this.pillTarget.disabled = false })
  }

  fail(attempted) {
    this.render(!attempted)
    this.status(this.failedLabelValue, "failed")
  }

  // `after` in ms: solo l'esito buono torna da sé alla dicitura di riposo. Un guasto resta scritto
  // finché non si riprova, altrimenti chi ha guardato altrove non sa che la modifica non è passata.
  status(text, tone, after = null) {
    if (!this.hasStatusTarget) return
    clearTimeout(this.statusTimer)
    this.statusTarget.textContent = text
    Object.entries(STATUS_TONES).forEach(([name, klass]) => {
      klass.split(" ").forEach((one) => this.statusTarget.classList.toggle(one, name === tone))
    })
    if (after) this.statusTimer = setTimeout(() => this.status(this.immediateLabelValue, "idle"), after)
  }

  render(checked) {
    this.checkedValue = checked
    this.pillTarget.setAttribute("aria-checked", checked ? "true" : "false")
    this.pillTarget.classList.toggle("bg-indigo-600", checked)
    this.pillTarget.classList.toggle("bg-stone-300", !checked)
    this.pillTarget.classList.toggle("dark:bg-zinc-600", !checked)
    this.knobTarget.classList.toggle("translate-x-[18px]", checked)
    this.knobTarget.classList.toggle("translate-x-[2px]", !checked)
  }

  get csrf() {
    return document.querySelector('meta[name="csrf-token"]')?.content || ""
  }
}
