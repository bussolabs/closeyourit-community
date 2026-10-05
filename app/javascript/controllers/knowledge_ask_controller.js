import { Controller } from "@hotwired/stimulus"

// "Chiedi alla KB" (RAG): POST della domanda → 202 con request_id → poll dell'esito. ASINCRONO
// (CYRA-275): la ricerca gira su un worker, la richiesta web ritorna subito. Clone di ticket-ask con
// citazioni a forma pagina (tipo + titolo). Senza JS la pagina mostra solo il form inerte.
export default class extends Controller {
  static targets = ["input", "submit", "status", "result", "answer", "answerWrapper", "citations", "citationsWrapper", "insufficient", "scopeNotice"]
  static values = { url: String, pollUrl: String, failedMessage: String, pendingMessage: String }

  // Domanda d'esempio (CYRA-421 Scenario 1): riempie il campo e parte subito, "con un clic". Le pill
  // restano nel DOM mentre si scrive — a differenza del placeholder che spariva alla prima lettera.
  useSample(event) {
    this.inputTarget.value = event.params.question
    this.submit()
  }

  // Storico (Scenario 3): rimette una domanda già posta nel campo per rifarla o modificarla, SENZA
  // rilanciarla in automatico (la sua risposta è già consultabile nel dettaglio aperto).
  fill(event) {
    this.inputTarget.value = event.params.question
    this.inputTarget.focus()
    this.inputTarget.scrollIntoView({ behavior: "smooth", block: "center" })
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
    // CYRA-831 — gemello di ticket-ask: la nota si accende prima del ramo "niente trovato", perché
    // è la risposta vuota a sembrare un fatto sulla knowledge base invece che un accesso cambiato.
    this.scopeNoticeTarget.hidden = !data.scope_reduced

    if (data.insufficient) {
      this.answerTarget.textContent = ""
      this.answerWrapperTarget.hidden = true
      this.citationsWrapperTarget.hidden = true
      this.insufficientTarget.hidden = false
      return
    }

    this.insufficientTarget.hidden = true

    // Prima le pagine pertinenti, poi la risposta (Scenario 3): ogni blocco si nasconde da solo se vuoto.
    const pages = data.pages || []
    this.citationsWrapperTarget.hidden = pages.length === 0
    this.citationsTarget.replaceChildren(...pages.map((page) => this.citation(page)))

    const answer = data.answer || ""
    this.answerTarget.textContent = answer
    this.answerWrapperTarget.hidden = answer.length === 0
  }

  citation(page) {
    const li = document.createElement("li")
    const link = document.createElement("a")
    link.href = page.url
    link.className = "inline-flex items-baseline gap-1.5 text-[12.5px] text-indigo-600 dark:text-indigo-400 hover:text-indigo-700 dark:hover:text-indigo-300"
    link.dataset.test = "knowledge-ask-citation"

    const kind = document.createElement("span")
    kind.className = "shrink-0 font-mono uppercase text-[9px] tracking-[1px] text-violet-600 dark:text-violet-400"
    kind.textContent = page.kind_label || page.kind

    const title = document.createElement("span")
    title.className = "underline underline-offset-2 decoration-indigo-200 dark:decoration-indigo-500/60"
    title.textContent = page.title

    link.append(kind, title)
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
