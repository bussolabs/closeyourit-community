import { Controller } from "@hotwired/stimulus"

// Idee simili mentre si propone un'idea: debounce sul title (min chars), re-check al blur del
// problema, POST /member/ideas/duplicates → pannello "idee simili" con link, stato e voti.
// SOLO suggerimento: il submit non è mai bloccato; su errore o zero risultati il pannello sparisce.
// Progressive enhancement: senza JS il pannello resta hidden e il form è identico a prima.
export default class extends Controller {
  static targets = ["panel", "list"]
  static values = { url: String, minChars: { type: Number, default: 8 } }

  connect() {
    // Il problema vive fuori da questo sotto-albero: bind manuale con teardown in disconnect.
    this.problem = document.querySelector('[data-test="idea-problem-field"]')
    this.onProblemBlur = () => this.fetchNow()
    this.problem?.addEventListener("blur", this.onProblemBlur)
  }

  disconnect() {
    clearTimeout(this.timer)
    this.problem?.removeEventListener("blur", this.onProblemBlur)
  }

  // input sul title → debounce 600ms
  queue() {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.fetchNow(), 600)
  }

  async fetchNow() {
    const title = this.titleInput?.value.trim() || ""
    if (title.length < this.minCharsValue) {
      this.hide()
      return
    }

    const text = [title, this.problem?.value.trim()].filter(Boolean).join("\n")
    try {
      const response = await fetch(this.urlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
          "X-CSRF-Token": this.csrfToken,
        },
        body: JSON.stringify({ text }),
      })
      if (!response.ok) {
        this.hide()
        return
      }
      const payload = await response.json().catch(() => ({}))
      this.render(payload?.data?.ideas || [])
    } catch (_error) {
      this.hide() // servizio giù → nessun rumore, il form resta usabile
    }
  }

  render(ideas) {
    if (ideas.length === 0) {
      this.hide()
      return
    }
    this.listTarget.replaceChildren(...ideas.map((idea) => this.item(idea)))
    this.panelTarget.hidden = false
  }

  item(idea) {
    const li = document.createElement("li")
    const link = document.createElement("a")
    link.href = idea.url
    link.target = "_blank"
    link.rel = "noopener"
    link.className = "inline-flex items-baseline gap-1.5 text-[12px] text-amber-900 dark:text-amber-200 hover:text-amber-700 dark:hover:text-amber-300"
    link.dataset.test = "idea-duplicates-item"

    const title = document.createElement("span")
    title.className = "underline decoration-amber-300 underline-offset-2"
    title.textContent = idea.title

    const project = document.createElement("span")
    project.className = "text-[10.5px] text-amber-700 dark:text-amber-300"
    project.textContent = idea.project || ""

    const status = document.createElement("span")
    status.className = "text-[10.5px] uppercase tracking-wide text-amber-600 dark:text-amber-400"
    status.textContent = idea.status_label || ""

    // I voti dicono quante persone vogliono già quella cosa: è il numero che convince ad aderire
    // invece di riproporla.
    const votes = document.createElement("span")
    votes.className = "font-mono text-[10.5px] text-amber-700 dark:text-amber-300"
    votes.textContent = `${idea.votes_count ?? 0} ★`

    link.append(title, project, status, votes)
    li.appendChild(link)
    return li
  }

  hide() {
    this.panelTarget.hidden = true
    this.listTarget.replaceChildren()
  }

  get titleInput() {
    return this.element.querySelector('[data-test="idea-title"]')
  }

  get csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content
  }
}
