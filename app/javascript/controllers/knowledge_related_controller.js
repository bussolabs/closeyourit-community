import { Controller } from "@hotwired/stimulus"

// Pannello "Knowledge correlata" (show ticket / gruppo errori): al connect chiede al server le
// pagine KB semanticamente vicine al record (POST perché calcola, non muta). Zero risultati o
// servizio giù → il pannello SPARISCE (CYRA-391): un titolo con sotto «non c'è niente» è una riga
// da saltare, e su queste pagine se ne accumulavano diverse di fila. Se il dato non c'è, non c'è
// nemmeno la sezione.
export default class extends Controller {
  static targets = ["list", "empty", "loading", "card"]
  static values = { url: String }

  connect() {
    this.load()
  }

  async load() {
    try {
      const response = await fetch(this.urlValue, {
        method: "POST",
        headers: { Accept: "application/json", "X-CSRF-Token": this.csrfToken },
      })
      if (!response.ok) return this.showEmpty()

      const payload = await response.json().catch(() => ({}))
      this.render(payload?.data?.pages || [])
    } catch (_error) {
      this.showEmpty() // servizio giù → nessun rumore
    }
  }

  render(pages) {
    this.loadingTarget.hidden = true
    if (pages.length === 0) return this.showEmpty()

    this.listTarget.replaceChildren(...pages.map((page) => this.item(page)))
    this.listTarget.hidden = false
    this.emptyTarget.hidden = true
  }

  item(page) {
    const li = document.createElement("li")
    const link = document.createElement("a")
    link.href = page.url
    link.target = "_blank"
    link.rel = "noopener"
    link.className = "flex items-baseline gap-1.5 text-[12px] text-zinc-700 dark:text-zinc-300 hover:text-indigo-600 dark:hover:text-indigo-400"
    link.dataset.test = "knowledge-related-item"

    const kind = document.createElement("span")
    kind.className = "shrink-0 font-mono uppercase text-[9px] tracking-[1px] text-violet-600 dark:text-violet-400"
    kind.textContent = page.kind_label || page.kind

    const title = document.createElement("span")
    title.className = "underline decoration-stone-300 dark:decoration-zinc-600 underline-offset-2"
    title.textContent = page.title

    link.append(kind, title)
    li.appendChild(link)

    // CYRA-414: perché questa pagina è qui, in poche parole (i termini in comune o la sezione che
    // ne parla). Arriva già tradotta dal server; senza motivo la riga non sarebbe nemmeno arrivata.
    if (page.reason) {
      const reason = document.createElement("p")
      reason.className = "mt-0.5 text-[11px] text-gray-500 dark:text-zinc-400"
      reason.dataset.test = "knowledge-related-reason"
      reason.textContent = page.reason
      li.appendChild(reason)
    }
    return li
  }

  // Niente da mostrare: via l'intera card. Il target `card` è opzionale — dove non c'è (altre
  // superfici che usano lo stesso pannello) resta il messaggio quieto di prima.
  showEmpty() {
    this.loadingTarget.hidden = true
    this.listTarget.hidden = true
    if (this.hasCardTarget) return this.cardTarget.remove()

    this.emptyTarget.hidden = false
  }

  get csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content
  }
}
