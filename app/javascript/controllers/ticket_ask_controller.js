import { Controller } from "@hotwired/stimulus"

// "Chiedi ai ticket" (RAG): POST della domanda → 202 con request_id → poll dell'esito. ASINCRONO
// (CYRA-275): la ricerca gira su un worker, la richiesta web ritorna subito e non tiene occupato un
// thread web per minuti. Busy state + messaggio "in corso" durante l'attesa, envelope error →
// messaggio pulito. Progressive enhancement: senza JS la pagina mostra solo il form inerte.
export default class extends Controller {
  static targets = ["input", "submit", "status", "result", "answer", "citations", "citationsWrapper", "insufficient", "scopeNotice"]
  static values = { url: String, pollUrl: String, failedMessage: String, pendingMessage: String }

  // CYRA-396 — una domanda già scritta (esempio o cronologia) entra nel campo e resta modificabile:
  // si parte da qualcosa che funziona invece che dal bianco.
  useExample(event) {
    this.inputTarget.value = event.currentTarget.dataset.question
    this.inputTarget.focus()
  }

  async submit() {
    const question = this.inputTarget.value.trim()
    if (!question) {
      this.inputTarget.focus()
      return
    }

    this.setBusy(true)
    this.resultTarget.hidden = true
    this.showStatus(this.pendingMessageValue)
    try {
      const response = await fetch(this.urlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
          "X-CSRF-Token": this.csrfToken,
        },
        body: JSON.stringify({ question }),
      })
      const payload = await response.json().catch(() => ({}))
      if (!response.ok) {
        this.showStatus(payload?.error?.message || this.failedMessageValue)
        return
      }
      // 202 + request_id: l'esito si polla (thread web libero). Senza request_id (mai, oggi) rende inline.
      const requestId = payload?.data?.request_id
      const result = requestId ? await this.poll(requestId) : payload.data || {}
      this.render(result)
    } catch (error) {
      this.showStatus(error.userMessage || this.failedMessageValue)
    } finally {
      this.setBusy(false)
    }
  }

  async poll(requestId) {
    const url = this.pollUrlValue.replace(":id", requestId)
    // Cap del client più largo di #compose (solo modello): il RAG somma embedding + rerank + modello.
    const deadline = Date.now() + 120000
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

  render(data) {
    this.statusTarget.hidden = true
    this.resultTarget.hidden = false
    // CYRA-831 — l'accesso tolto mentre la domanda era in coda restringe la risposta (il server la
    // costruisce sul perimetro di adesso). La nota va accesa PRIMA del ramo "niente trovato": è
    // proprio la risposta vuota che, senza spiegazione, si legge come un fatto sull'archivio.
    this.scopeNoticeTarget.hidden = !data.scope_reduced

    if (data.insufficient) {
      this.answerTarget.textContent = ""
      this.citationsWrapperTarget.hidden = true
      this.insufficientTarget.hidden = false
      return
    }

    this.insufficientTarget.hidden = true
    this.answerTarget.textContent = data.answer || ""

    const tickets = data.tickets || []
    this.citationsWrapperTarget.hidden = tickets.length === 0
    this.citationsTarget.replaceChildren(...tickets.map((ticket) => this.citation(ticket)))
  }

  citation(ticket) {
    const li = document.createElement("li")
    const link = document.createElement("a")
    link.href = ticket.url
    link.className = "inline-flex items-baseline gap-1.5 text-[12.5px] text-indigo-600 dark:text-indigo-400 hover:text-indigo-700 dark:hover:text-indigo-300"
    link.dataset.test = "tickets-ask-citation"

    const code = document.createElement("span")
    code.className = "font-mono text-[11px]"
    code.textContent = ticket.code

    const title = document.createElement("span")
    title.className = "underline underline-offset-2 decoration-indigo-200 dark:decoration-indigo-500/60"
    title.textContent = ticket.title

    const status = document.createElement("span")
    status.className = "text-[10.5px] uppercase tracking-wide text-gray-400 dark:text-zinc-500"
    status.textContent = ticket.status_label || ""

    link.append(code, title, status)
    li.appendChild(link)
    return li
  }

  showStatus(message) {
    this.statusTarget.textContent = message
    this.statusTarget.hidden = false
  }

  setBusy(busy) {
    this.submitTarget.disabled = busy
    this.element.classList.toggle("opacity-75", busy)
  }

  get csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content
  }
}
