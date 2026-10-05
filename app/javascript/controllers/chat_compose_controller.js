import { Controller } from "@hotwired/stimulus"

// Composer del messaggio: invio con Enter (Shift+Enter = a capo) + picker di risorse taggabili.
//
// Picker: mentre si digita, se la parola corrente inizia con "#" interroghiamo l'endpoint taggable
// (autocomplete ristretto all'intersezione dei partecipanti, lato server) e mostriamo i suggerimenti;
// selezionandone uno si inserisce il token canonico (#CODE o cyi:tipo:id) nel testo. Il vincolo
// "in comune" è imposto dal server (qui e di nuovo al salvataggio).
export default class extends Controller {
  static targets = ["input", "suggestions"]
  static values = { taggableUrl: String }

  maybeSubmit(event) {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault()
      this.element.requestSubmit()
    }
  }

  disconnect() {
    clearTimeout(this.searchTimeout)
  }

  // Chiamato all'input (action nella view, insieme a chat-conversation#typing). Debounce: una sola
  // richiesta a fine digitazione, non una per tasto (l'endpoint taggable costa O(partecipanti) query).
  search() {
    clearTimeout(this.searchTimeout)
    this.searchTimeout = setTimeout(() => this.performSearch(), 200)
  }

  async performSearch() {
    const word = this.currentWord()
    if (!word.startsWith("#") || word.length < 2) return this.hideSuggestions()

    try {
      const url = `${this.taggableUrlValue}?q=${encodeURIComponent(word.slice(1))}`
      const response = await fetch(url, { headers: { Accept: "application/json" } })
      if (!response.ok) return this.hideSuggestions()
      const { data } = await response.json()
      this.renderSuggestions(data || [])
    } catch (_error) {
      this.hideSuggestions()
    }
  }

  renderSuggestions(items) {
    if (!this.hasSuggestionsTarget) return
    if (items.length === 0) return this.hideSuggestions()

    // Costruzione via DOM (textContent/dataset): nessun innerHTML con dati non fidati → no XSS.
    this.suggestionsTarget.replaceChildren(...items.map((item) => this.suggestionButton(item)))
    this.suggestionsTarget.classList.remove("hidden")
  }

  suggestionButton(item) {
    const button = document.createElement("button")
    button.type = "button"
    button.dataset.action = "chat-compose#pick"
    button.dataset.token = item.token == null ? "" : String(item.token)
    button.className = "block w-full px-3 py-1.5 text-left hover:bg-zinc-50 dark:hover:bg-zinc-800"

    const label = document.createElement("span")
    label.className = "font-medium"
    label.textContent = item.label == null ? "" : String(item.label)

    const hint = document.createElement("span")
    hint.className = "ml-1 text-zinc-400"
    hint.textContent = item.hint == null ? "" : String(item.hint)

    button.append(label, hint)
    return button
  }

  pick(event) {
    const token = event.currentTarget.dataset.token
    const value = this.inputTarget.value
    const end = this.inputTarget.selectionStart
    const start = value.lastIndexOf("#", end - 1)
    this.inputTarget.value = `${value.slice(0, start)}${token} ${value.slice(end)}`
    this.hideSuggestions()
    this.inputTarget.focus()
  }

  hideSuggestions() {
    if (this.hasSuggestionsTarget) {
      this.suggestionsTarget.classList.add("hidden")
      this.suggestionsTarget.innerHTML = ""
    }
  }

  currentWord() {
    const value = this.inputTarget.value.slice(0, this.inputTarget.selectionStart)
    return value.split(/\s/).pop() || ""
  }
}
