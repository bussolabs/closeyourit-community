import { Controller } from "@hotwired/stimulus"

// CYRA-364 — opzioni di un `ui--select` prese dal server MENTRE si digita, invece di caricarle
// tutte insieme alla pagina. Sta sullo stesso elemento di `ui--select` e non disegna niente: la
// ricerca, la tastiera e l'accessibilità restano sue. Qui si sostituiscono le <option> del
// <select> nativo e si dispatcha `ui--select:refresh`, che è il punto di ri-sincronizzazione già
// dichiarato dal widget per chi ne muta le opzioni dall'esterno.
//
// Senza JS resta il <select> nativo con le poche voci rese dal server (le più aggiornate del
// contesto): il campo funziona lo stesso, solo senza ricerca.
//
// Il campo di ricerca lo costruisce `ui--select` dentro il proprio pannello, quindi non è un
// target dichiarabile: si ascolta l'evento `input` che risale fino a qui.
export default class extends Controller {
  static targets = ["select", "all"]
  static values = {
    url: String,
    // Selettore CSS del campo che porta il contesto (es. il select del team nel form): letto ad
    // ogni ricerca, così cambiando team i risultati seguono senza ricaricare la pagina.
    scopeField: String,
    scopeParam: { type: String, default: "team_id" },
    delay: { type: Number, default: 200 }
  }

  connect() {
    this.onInput = this.onInput.bind(this)
    this.element.addEventListener("input", this.onInput)
  }

  disconnect() {
    this.element.removeEventListener("input", this.onInput)
    clearTimeout(this.timer)
  }

  // Debounce: una richiesta a fine digitazione, non una per tasto.
  onInput(event) {
    if (event.target === this.selectTarget) return
    const query = event.target.value
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.load(query), this.delayValue)
  }

  // Dalla casella «cerca in tutti i progetti»: rilancia la ricerca corrente col nuovo perimetro.
  reload() {
    clearTimeout(this.timer)
    this.load(this.currentQuery())
  }

  async load(query) {
    const params = new URLSearchParams()
    if (query) params.set("q", query)
    if (this.hasAllTarget && this.allTarget.checked) params.set("all", "1")
    const scope = this.scopeValue()
    if (scope) params.set(this.scopeParamValue, scope)

    try {
      const response = await fetch(`${this.urlValue}?${params}`, { headers: { Accept: "application/json" } })
      if (!response.ok) return
      const { data } = await response.json()
      this.replaceOptions(data || [])
    } catch (_error) {
      // Rete assente o risposta illeggibile: restano le opzioni correnti, che sono valide.
    }
  }

  // La riga vuota e la scelta già fatta sopravvivono sempre alla sostituzione: la prima è l'unico
  // modo per togliere il collegamento, la seconda sparirebbe dal <select> appena la ricerca cambia
  // — e con lei il valore che il form submette.
  replaceOptions(items) {
    const select = this.selectTarget
    const chosen = select.options[select.selectedIndex]
    const keep = []
    const blank = select.querySelector('option[value=""]')
    if (blank) keep.push(blank)
    if (chosen && chosen.value) keep.push(chosen)

    const kept = new Set(keep.map((option) => option.value))
    // textContent (mai innerHTML): le etichette sono testo scritto dagli utenti → niente XSS.
    const fresh = items
      .filter((item) => !kept.has(String(item.id)))
      .map((item) => {
        const option = document.createElement("option")
        option.value = item.id == null ? "" : String(item.id)
        option.textContent = item.label == null ? "" : String(item.label)
        return option
      })

    select.replaceChildren(...keep, ...fresh)
    if (chosen) chosen.selected = true
    select.dispatchEvent(new CustomEvent("ui--select:refresh"))
  }

  currentQuery() {
    const search = this.element.querySelector('input[role="combobox"]')
    return search ? search.value : ""
  }

  scopeValue() {
    if (!this.hasScopeFieldValue || this.scopeFieldValue === "") return null
    const field = document.querySelector(this.scopeFieldValue)
    return field && field.value ? field.value : null
  }
}
