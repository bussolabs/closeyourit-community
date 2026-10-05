import { Controller } from "@hotwired/stimulus"

// Triage AI on-demand per gruppi errore / metrica. Il pulsante chiede al backend
// (POST .../triage_ai) un verdetto strutturato e lo renderizza; per gli errori un secondo
// pulsante cerca gruppi con la stessa causa (POST .../similar). L'azione consigliata viene
// pre-evidenziata sui pulsanti nativi (resolve/ignore/promote): l'umano applica con un clic.
// Progressive enhancement: senza JS il pannello non compare e i pulsanti triage/promote in cima
// alla pagina restano usabili a mano.
export default class extends Controller {
  static targets = [
    "suggestButton", "similarButton", "status", "result",
    "category", "severity", "confidence", "rootCause", "fix", "summary",
    "action", "actionNone", "similarResult", "similarEmpty", "similarList",
  ]
  static values = {
    triageUrl: String, similarUrl: String, pollUrl: String,
    failed: String, analyzing: String, similarAnalyzing: String, similarEmpty: String,
  }

  async suggest() {
    this.setBusy(this.suggestButtonTarget, true)
    this.showStatus(this.analyzingValue, "muted")
    try {
      const data = await this.post(this.triageUrlValue)
      if (data) this.renderVerdict(data)
    } finally {
      this.setBusy(this.suggestButtonTarget, false)
    }
  }

  async findSimilar() {
    this.setBusy(this.similarButtonTarget, true)
    this.showStatus(this.similarAnalyzingValue, "muted")
    try {
      const data = await this.post(this.similarUrlValue)
      if (data) {
        this.renderSimilar(data)
        this.hideStatus()
      }
    } finally {
      this.setBusy(this.similarButtonTarget, false)
    }
  }

  // L'endpoint accoda il lavoro AI e risponde 202 con un request_id: il verdetto arriva
  // pollando /member/ai/requests/:id (il gateway impiega ~30s; il server non blocca più).
  async post(url) {
    try {
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
        this.showStatus(payload?.error?.message || this.failedValue, "error")
        return null
      }
      const requestId = payload?.data?.request_id
      if (!requestId) return payload.data || {}
      return await this.poll(requestId)
    } catch (error) {
      this.showStatus(error.userMessage || this.failedValue, "error")
      return null
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

  renderVerdict(data) {
    this.setText(this.categoryTarget, data.category)
    if (this.hasSeverityTarget) this.setText(this.severityTarget, data.severity_suggested || data.severity)
    this.setText(this.confidenceTarget, data.confidence)
    this.setText(this.rootCauseTarget, data.root_cause)
    if (this.hasFixTarget) this.setText(this.fixTarget, data.suggested_fix)
    this.setText(this.summaryTarget, data.summary)
    this.highlightAction(data.suggested_action)
    this.resultTarget.classList.remove("hidden")
    this.hideStatus()
  }

  // Mostra ed evidenzia il solo pulsante d'azione corrispondente al suggerimento; se nessuno
  // combacia (es. "none", o l'azione non è applicabile in questo stato) mostra l'hint neutro.
  highlightAction(suggested) {
    let matched = false
    this.actionTargets.forEach((element) => {
      if (element.dataset.actionKind === suggested) {
        element.classList.remove("hidden")
        element.classList.add("ring-2", "ring-indigo-400", "ring-offset-1")
        matched = true
      } else {
        element.classList.add("hidden")
        element.classList.remove("ring-2", "ring-indigo-400", "ring-offset-1")
      }
    })
    if (this.hasActionNoneTarget) this.actionNoneTarget.classList.toggle("hidden", matched)
  }

  renderSimilar(data) {
    const groups = data.groups || []
    this.similarListTarget.replaceChildren()
    if (groups.length === 0) {
      this.similarEmptyTarget.textContent = this.similarEmptyValue
      this.similarEmptyTarget.classList.remove("hidden")
    } else {
      this.similarEmptyTarget.classList.add("hidden")
      groups.forEach((group) => {
        const item = document.createElement("li")
        const link = document.createElement("a")
        link.href = group.url
        link.className = "block rounded-md border border-stone-200 dark:border-zinc-800 px-2.5 py-1.5 hover:bg-stone-50 dark:hover:bg-zinc-800 text-[12px] text-zinc-700 dark:text-zinc-300"
        link.textContent = group.title
        item.appendChild(link)
        this.similarListTarget.appendChild(item)
      })
    }
    this.similarResultTarget.classList.remove("hidden")
  }

  setText(element, value) {
    if (element) element.textContent = value == null || value === "" ? "—" : value
  }

  setBusy(button, busy) {
    if (button) button.disabled = busy
  }

  showStatus(message, kind) {
    if (!this.hasStatusTarget) return
    this.statusTarget.textContent = message
    this.statusTarget.classList.remove("hidden", "text-red-600", "dark:text-red-400", "text-gray-500", "dark:text-zinc-400")
    this.statusTarget.classList.add(...(kind === "error" ? [ "text-red-600", "dark:text-red-400" ] : [ "text-gray-500", "dark:text-zinc-400" ]))
  }

  hideStatus() {
    if (this.hasStatusTarget) this.statusTarget.classList.add("hidden")
  }

  get csrfToken() {
    const meta = document.querySelector("meta[name='csrf-token']")
    return meta ? meta.content : ""
  }
}
