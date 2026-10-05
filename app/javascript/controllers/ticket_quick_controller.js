import { Controller } from "@hotwired/stimulus"

// Modalità rapida bug-report: l'utente scrive la segnalazione in linguaggio naturale, preme il bottone
// e l'assistente AI (POST /member/tickets/analyze) ricostruisce uno o più scenari BDD (riempiendo il
// repeater scenari + l'analisi tecnica), oppure restituisce domande di chiarimento (loop single-shot:
// l'utente integra il testo e ripreme). Gli scenari restano la verità del form (validati lato server):
// è solo input-assist. Progressive enhancement: senza JS gli scenari sono compilabili a mano.
export default class extends Controller {
  static targets = ["quickText", "analyzeButton", "questions", "questionsList", "status"]
  static values = { analyzeUrl: String, pollUrl: String, projectId: String, completeMessage: String, failedMessage: String }

  async analyze(event) {
    event.preventDefault()
    const text = this.quickTextTarget.value.trim()
    if (!text) {
      this.quickTextTarget.focus()
      return
    }

    this.setBusy(true)
    try {
      const response = await fetch(this.analyzeUrlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
          "X-CSRF-Token": this.csrfToken,
        },
        body: JSON.stringify({ project_id: this.projectIdValue, quick_text: text }),
      })
      const payload = await response.json().catch(() => ({}))
      if (!response.ok) {
        this.showStatus(payload?.error?.message || this.failedMessageValue, "error")
        return
      }
      // 202 + request_id: l'analisi gira in background, l'esito si polla (il server non blocca più).
      const requestId = payload?.data?.request_id
      this.apply(requestId ? await this.poll(requestId) : payload.data || {})
    } catch (error) {
      this.showStatus(error.userMessage || this.failedMessageValue, "error")
    } finally {
      this.setBusy(false)
    }
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

  apply(data) {
    if (data.complete) {
      this.fillScenarios(data.scenarios || [])
      this.setTechnicalAnalysis(data.technical_analysis)
      this.hideQuestions()
      this.showStatus(this.completeMessageValue, "ok")
    } else {
      this.renderQuestions(data.questions || [])
    }
  }

  // Sostituisce le righe del repeater scenari con quelle ricostruite dall'AI (solo su form nuovo).
  fillScenarios(scenarios) {
    const controller = this.scenariosController()
    if (controller && scenarios.length) controller.replaceRows(scenarios)
  }

  setTechnicalAnalysis(value) {
    if (value == null) return
    const field = document.querySelector("[name='technical_analysis']")
    if (!field) return

    field.value = value
    // Riempire .value non emette `input`: il contatore caratteri va notificato a mano.
    field.dispatchEvent(new Event("input", { bubbles: true }))
  }

  scenariosController() {
    const element = document.querySelector("[data-nested-kind='scenarios']")
    return element ? this.application.getControllerForElementAndIdentifier(element, "nested-fields") : null
  }

  renderQuestions(questions) {
    this.questionsListTarget.replaceChildren()
    questions.forEach((question) => {
      const li = document.createElement("li")
      li.textContent = question
      this.questionsListTarget.appendChild(li)
    })
    this.questionsTarget.hidden = false
    this.hideStatus()
  }

  hideQuestions() {
    if (this.hasQuestionsTarget) this.questionsTarget.hidden = true
  }

  setBusy(busy) {
    if (this.hasAnalyzeButtonTarget) this.analyzeButtonTarget.disabled = busy
  }

  showStatus(message, kind) {
    if (!this.hasStatusTarget) return
    this.statusTarget.textContent = message
    this.statusTarget.classList.remove("hidden", "text-emerald-700", "dark:text-emerald-300", "text-red-600", "dark:text-red-400")
    this.statusTarget.classList.add(...(kind === "ok" ? [ "text-emerald-700", "dark:text-emerald-300" ] : [ "text-red-600", "dark:text-red-400" ]))
  }

  hideStatus() {
    if (this.hasStatusTarget) this.statusTarget.classList.add("hidden")
  }

  get csrfToken() {
    const meta = document.querySelector("meta[name='csrf-token']")
    return meta ? meta.content : ""
  }
}
