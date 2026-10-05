import { Controller } from "@hotwired/stimulus"

// Suggerimento dei titoli mentre si scrive un wikilink `[[…]]` nel corpo di una pagina KB (CYRA-433).
//
// Il campo resta un semplice textarea: qui guardiamo solo il testo a sinistra del cursore. Se c'è un
// `[[` ancora aperto (nessun `]]` dopo di lui, e sulla stessa riga — come vuole Links::Parse),
// quello che segue è la ricerca e chiediamo i titoli al server, che li restringe alle pagine
// visibili a chi scrive. Scelto un titolo, lo inseriamo e chiudiamo noi le parentesi.
//
// Nessun testo nasce qui: titolo ed etichetta del tipo arrivano tradotti dal server (regola della
// lingua). Servizio irraggiungibile o risposta storta → l'elenco resta chiuso e si continua a
// scrivere a mano: un aiuto di digitazione non può mai bloccare la scrittura di una pagina.
export default class extends Controller {
  static targets = ["field", "suggestions"]
  static values = { url: String, excludeId: String }

  disconnect() {
    clearTimeout(this.searchTimeout)
  }

  // Debounce: una richiesta a fine digitazione, non una per tasto.
  search() {
    clearTimeout(this.searchTimeout)
    this.searchTimeout = setTimeout(() => this.performSearch(), 200)
  }

  async performSearch() {
    const query = this.openLinkQuery()
    if (query === null) return this.hide()

    try {
      const params = new URLSearchParams({ q: query })
      if (this.hasExcludeIdValue && this.excludeIdValue) params.set("exclude_id", this.excludeIdValue)
      const response = await fetch(`${this.urlValue}?${params}`, { headers: { Accept: "application/json" } })
      if (!response.ok) return this.hide()

      const payload = await response.json().catch(() => ({}))
      this.render(payload?.data || [])
    } catch (_error) {
      this.hide()
    }
  }

  render(items) {
    if (!this.hasSuggestionsTarget) return
    if (items.length === 0) return this.hide()

    // Costruzione via DOM (textContent/dataset): nessun innerHTML con dati non fidati → no XSS.
    this.suggestionsTarget.replaceChildren(...items.map((item) => this.suggestionButton(item)))
    this.suggestionsTarget.classList.remove("hidden")
  }

  suggestionButton(item) {
    const button = document.createElement("button")
    button.type = "button"
    button.dataset.action = "knowledge-links#pick"
    button.dataset.test = "knowledge-links-suggestion"
    button.dataset.title = item.title == null ? "" : String(item.title)
    button.className = "flex w-full items-baseline gap-2 px-3 py-1.5 text-left hover:bg-stone-50 dark:hover:bg-zinc-800"

    const title = document.createElement("span")
    title.className = "text-[12.5px] text-zinc-900 dark:text-zinc-100"
    title.textContent = button.dataset.title

    const hint = document.createElement("span")
    hint.className = "font-mono uppercase text-[9.5px] tracking-[1px] text-gray-500 dark:text-zinc-400"
    hint.textContent = item.hint == null ? "" : String(item.hint)

    button.append(title, hint)
    return button
  }

  // Sostituisce la parte già digitata dopo `[[` col titolo scelto e chiude le parentesi, saltando
  // il `]]` che l'editor potrebbe aver già scritto (per non lasciarne quattro).
  pick(event) {
    const title = event.currentTarget.dataset.title
    const field = this.fieldTarget
    const cursor = field.selectionStart
    const opening = field.value.lastIndexOf("[[", cursor - 1)
    const rest = field.value.slice(cursor)
    const tail = rest.startsWith("]]") ? rest.slice(2) : rest

    field.value = `${field.value.slice(0, opening)}[[${title}]]${tail}`
    const caret = opening + title.length + 4
    this.hide()
    field.focus()
    field.setSelectionRange(caret, caret)
    // Il contatore di caratteri ascolta `input`: senza, il testo inserito non verrebbe contato.
    field.dispatchEvent(new Event("input", { bubbles: true }))
  }

  // Testo digitato dentro un `[[` ancora aperto, oppure null se il cursore non è in un collegamento.
  openLinkQuery() {
    const before = this.fieldTarget.value.slice(0, this.fieldTarget.selectionStart)
    const opening = before.lastIndexOf("[[")
    if (opening === -1) return null

    const typed = before.slice(opening + 2)
    // Un collegamento vive su una riga sola e si chiude con `]]`: oltre non è più aperto. Dopo la
    // barra verticale si scrive il testo mostrato, non il titolo: lì non c'è più niente da cercare.
    if (/[[\]|\n]/.test(typed)) return null

    return typed
  }

  // Escape chiude l'elenco senza toccare il testo: si continua a scrivere il titolo a mano.
  dismiss(event) {
    if (event.key === "Escape") this.hide()
  }

  hide() {
    if (!this.hasSuggestionsTarget) return

    this.suggestionsTarget.classList.add("hidden")
    this.suggestionsTarget.replaceChildren()
  }
}
