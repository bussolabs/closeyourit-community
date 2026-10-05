import { Controller } from "@hotwired/stimulus"
import { icon } from "lib/icon"

// Preview di conversione idea → ticket: al connect accoda la sintesi AI (POST synthesis → 202
// con request_id) e polla /member/ai/requests/:id finché done, poi riempie titolo e descrizione.
// I campi partono col fallback (titolo/corpo dell'idea) e restano SEMPRE editabili/submittabili:
// l'AI è un assist, non un gate. "Rigenera" riesegue la sintesi sovrascrivendo i campi.
// Progressive enhancement: senza JS il form funziona col solo fallback.
export default class extends Controller {
  static targets = ["title", "description", "status", "regenerate"]
  static values = {
    url: String, pollUrl: String,
    generating: String, done: String, failed: String,
  }

  connect() {
    this.generate()
  }

  regenerate() {
    this.generate()
  }

  async generate() {
    this.setBusy(true)
    this.showStatus(this.generatingValue, "busy")
    try {
      const draft = await this.post(this.urlValue)
      if (draft) {
        this.titleTarget.value = draft.title || this.titleTarget.value
        this.descriptionTarget.value = draft.description || this.descriptionTarget.value
        this.showStatus(this.doneValue, "ok")
      }
    } catch (error) {
      this.showStatus(error.userMessage || this.failedValue, "error")
    } finally {
      this.setBusy(false)
    }
  }

  // POST → 202 {request_id} → poll. Errori HTTP → messaggio nel banner, campi fallback intatti.
  async post(url) {
    const response = await fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json",
        "X-CSRF-Token": this.csrfToken,
      },
    })
    const payload = await response.json().catch(() => ({}))
    if (!response.ok) {
      const error = new Error(payload?.error?.message || "failed")
      error.userMessage = payload?.error?.message
      throw error
    }
    const requestId = payload?.data?.request_id
    if (!requestId) return payload.data || {}
    return await this.poll(requestId)
  }

  async poll(requestId) {
    const url = this.pollUrlValue.replace(":id", requestId)
    const deadline = Date.now() + 90000
    while (Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 1500))
      const response = await fetch(url, { headers: { Accept: "application/json" } })
      if (!response.ok) break
      const data = (await response.json().catch(() => ({})))?.data || {}
      if (data.status === "done") return data.result || {}
      if (data.status === "failed") {
        const error = new Error(data.error?.message || "failed")
        error.userMessage = data.error?.message
        throw error
      }
    }
    throw new Error("timeout")
  }

  setBusy(busy) {
    this.titleTarget.readOnly = busy
    this.descriptionTarget.readOnly = busy
    this.titleTarget.classList.toggle("opacity-60", busy)
    this.descriptionTarget.classList.toggle("opacity-60", busy)
    if (this.hasRegenerateTarget) {
      this.regenerateTarget.hidden = busy
      this.regenerateTarget.disabled = busy
    }
  }

  showStatus(text, tone) {
    const el = this.statusTarget
    el.hidden = false
    el.textContent = ""
    el.appendChild(tone === "error" ? icon("triangle-alert", "text-[12px]")
      : tone === "ok" ? icon("check", "text-[12px]")
      : icon("loader-circle", "text-[12px] animate-spin"))
    el.appendChild(document.createTextNode(" " + text))
    el.classList.toggle("border-red-200", tone === "error")
    el.classList.toggle("dark:border-red-500/40", tone === "error")
    el.classList.toggle("bg-red-50", tone === "error")
    el.classList.toggle("dark:bg-red-500/15", tone === "error")
    el.classList.toggle("text-red-800", tone === "error")
    el.classList.toggle("dark:text-red-200", tone === "error")
    el.classList.toggle("border-indigo-200", tone !== "error")
    el.classList.toggle("dark:border-indigo-500/40", tone !== "error")
    el.classList.toggle("bg-indigo-50", tone !== "error")
    el.classList.toggle("dark:bg-indigo-500/15", tone !== "error")
    el.classList.toggle("text-indigo-900", tone !== "error")
    el.classList.toggle("dark:text-indigo-200", tone !== "error")
  }

  get csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content
  }
}
