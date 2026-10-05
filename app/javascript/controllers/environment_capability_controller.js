import { Controller } from "@hotwired/stimulus"

// Segmented control tri-state (Eredita/On/Off) delle capability [servers/uptime/secrets] di un ambiente
// dichiarato. Click ottimistico: seleziona subito il bottone, poi PATCH { capability, value } su urlValue.
// Su risposta non-2xx (o errore di rete) reverte la selezione. Senza JS i bottoni sono inerti: la
// persistenza è coperta dal request spec (rack_test non esegue Stimulus).
export default class extends Controller {
  static values = { url: String }

  set(event) {
    if (this.saving) return
    const button = event.currentTarget
    const { capability, value, reload } = event.params
    const group = button.closest("[data-capability-group]")
    const previous = group.querySelector('[aria-pressed="true"]')
    if (previous === button) return

    this.select(group, button)
    this.saving = true
    fetch(this.urlValue, {
      method: "PATCH",
      credentials: "same-origin",
      headers: {
        "X-CSRF-Token": this.csrf,
        Accept: "application/json",
        "Content-Type": "application/json"
      },
      body: JSON.stringify({ capability, value })
    })
      .then((response) => {
        if (!response.ok) { if (previous) this.select(group, previous); return }
        // CYRA-883: the server picker and the monitor link depend on Servers and Uptime.
        if (reload) window.Turbo?.visit(window.location.href, { action: "replace" })
      })
      .catch(() => { if (previous) this.select(group, previous) })
      .finally(() => { this.saving = false })
  }

  select(group, button) {
    group.querySelectorAll("button").forEach((b) => {
      const on = b === button
      b.setAttribute("aria-pressed", on ? "true" : "false")
      b.classList.toggle("bg-indigo-600", on)
      b.classList.toggle("text-white", on)
      b.classList.toggle("text-gray-600", !on)
      b.classList.toggle("dark:text-zinc-400", !on)
    })
  }

  get csrf() {
    return document.querySelector('meta[name="csrf-token"]')?.content || ""
  }
}
