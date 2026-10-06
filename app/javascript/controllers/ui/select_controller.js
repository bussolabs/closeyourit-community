import { Controller } from "@hotwired/stimulus"
import { icon } from "lib/icon"

// id univoco per istanza (listbox + opzioni) — condiviso dal modulo tra tutte le istanze.
let uid = 0

// Classe di evidenza tastiera sull'opzione attiva (aria-activedescendant).
const HIGHLIGHT = [ "bg-stone-100", "dark:bg-zinc-800" ]
const DEFAULT_PLACEHOLDER = "Select…"

// Searchable select (regola forms-select) resa come combobox WAI-ARIA accessibile.
// Progressive enhancement su un <select> nativo che mantiene il name: senza JS submette e si
// testa normalmente; con JS lo nasconde e mostra trigger + dropdown con ricerca, sincronizzando
// la selezione sul <select> (che submette). Semantica combobox (ARIA 1.2 "combobox with listbox"):
//   - trigger  = button disclosure (aria-haspopup=listbox, aria-expanded, aria-controls) sempre nel tab order
//   - search   = role="combobox" (aria-expanded/controls, aria-autocomplete=list, aria-activedescendant + nome)
//   - list     = role="listbox" (aria-multiselectable se multiple)
//   - opzione  = role="option" (aria-selected)
// Tastiera sul combobox: ArrowDown/Up spostano l'evidenza, Home/End primo/ultimo, Enter seleziona
// (single: chiude + focus al trigger; multi: resta aperto), Escape chiude + focus al trigger.
//
// Option hidden/disabled: il widget rispetta gli stessi flag del <select> nativo — un'opzione
// `hidden` non viene mostrata nella lista, una `disabled` resta visibile ma non selezionabile
// (grigia, esclusa da navigazione da tastiera e ricerca-match). Un controller esterno che muta
// queste opzioni IMPERATIVAMENTE (es. filtro milestone per progetto, blocco ruolo dataset per kind)
// deve poi far ri-sincronizzare il widget dispatchando `ui--select:refresh` sul <select> nativo
// (oltre al "change" nativo, già ascoltato, per i cambi di .value/.selected).
export default class extends Controller {
  static targets = ["select"]
  static values = {
    multiple: Boolean, summary: Boolean,
    placeholder: { type: String, default: DEFAULT_PLACEHOLDER },
    // Testi che il widget compone da solo: arrivano tradotti dal componente (CYRA-442). I default
    // servono solo a non lasciare il widget muto se un caller non li passa.
    selectedLabel: { type: String, default: "%{count} selected" },
    searchLabel: { type: String, default: "Search…" },
    // CYRA-883 — fixed words (and an icon) before the value, inside the same trigger.
    prefix: String,
    prefixIcon: String
  }

  connect() {
    if (this.enhanced) return
    this.enhanced = true
    this.select = this.selectTarget
    this.select.classList.add("sr-only")
    this.select.setAttribute("aria-hidden", "true")
    this.select.tabIndex = -1
    // Parità col <select> nativo: anche un'option con value="" è una scelta reale. Può essere
    // generata da include_blank ("Nessun gruppo") oppure dichiarata esplicitamente ("Qualsiasi
    // livello"). Scartarla qui rendeva impossibile azzerare un valore già scelto (CYRA-89).
    this.options = Array.from(this.select.options)

    // Id stabili per il collegamento ARIA (listbox ← combobox aria-controls; opzioni ← activedescendant).
    this.uid = `uisel-${++uid}`
    this.listboxId = `${this.uid}-listbox`
    this.activeIndex = -1
    // Nome accessibile: riusa la <label for> del componente (aria-labelledby) o il placeholder (aria-label).
    this.labelId = this.resolveLabelId()

    this.trigger = this.buildTrigger()
    this.panel = this.buildPanel()
    this.element.appendChild(this.trigger)
    this.element.appendChild(this.panel)
    this.renderList()
    this.renderTrigger()

    // Cambi programmatici al <select> nativo (es. prefill da ticket-platforms, filtro milestone
    // per progetto, blocco ruolo dataset per kind) → ri-sincronizza trigger e lista. choose() rende
    // già e poi dispatcha: il re-render è idempotente, niente loop. "ui--select:refresh" copre i
    // controller che mutano SOLO hidden/disabled (nessun cambio .value/.selected → nessun "change"
    // nativo da intercettare).
    this.select.addEventListener("change", () => this.sync())
    this.select.addEventListener("ui--select:refresh", () => this.sync())

    // isConnected: il click su un'opzione ri-renderizza la lista e stacca la riga cliccata dal
    // DOM — senza il check il panel si chiuderebbe a ogni pick (in multiple si vuole pick-pick-
    // pick e chiusura solo al click davvero fuori, che con ui--filter-bar fa UN solo submit).
    this.outside = (e) => { if (e.target.isConnected && !this.element.contains(e.target)) this.close() }
    document.addEventListener("click", this.outside)
  }

  disconnect() {
    if (this.outside) document.removeEventListener("click", this.outside)
    this.close()
  }

  // Punto unico di ri-sincronizzazione (native "change" + custom "ui--select:refresh"): rilegge le
  // option CORRENTI dal <select> nativo (un controller esterno può averle mutate: hidden/disabled/
  // selected) e ri-renderizza dropdown+trigger. Pannello aperto → riapplica il filtro di ricerca
  // corrente sulle righe appena create (renderList() perde lo stato hidden-da-ricerca, mantiene solo
  // hidden-da-dato) MA PRESERVA l'evidenza (applyActive, non filter/setActiveIndex): choose() su un
  // multi-select dispatcha "change" ad ogni pick e rientra qui — se resettassimo l'activeIndex alla
  // prima opzione visibile ad ogni sync(), l'evidenza salterebbe via dall'opzione appena scelta
  // dall'utente (regressione osservata su tutti i multi-select + ticket_platforms_controller.js, che
  // dispatcha "change" al cambio progetto). Il reset ad inizio lista resta SOLO in filter(), per la
  // ricerca da tastiera dove è il comportamento voluto.
  sync() {
    this.options = Array.from(this.select.options)
    this.renderList()
    this.renderTrigger()
    if (this.isOpen) {
      this.applyHiddenState()
      this.applyActive()
    }
  }

  get isOpen() { return !this.panel.classList.contains("hidden") }

  // La <label for="<id-del-select>"> vive nel wrapper, fuori da this.element (il div .relative).
  // Le diamo un id stabile per poterla referenziare via aria-labelledby dal combobox. Se non c'è
  // una <label> visibile ma il <select> nativo dichiara un nome accessibile proprio
  // (aria-labelledby o aria-label — componente `aria_label:`, celle dense senza label visibile),
  // lo eredita: altrimenti, nascondendo il nativo con aria-hidden (sopra), lo screen reader
  // perderebbe il nome. aria-labelledby referenzia un id già nel DOM; aria-label è un letterale →
  // sintetizziamo uno span sr-only col testo per riusare lo STESSO meccanismo aria-labelledby
  // (si ri-legge da solo ad ogni cambio di valore, niente ri-sync manuale in renderTrigger()).
  resolveLabelId() {
    const id = this.select.id
    if (id) {
      const scope = this.element.parentElement || document
      const label = scope.querySelector(`label[for="${CSS.escape(id)}"]`)
      if (label) {
        if (!label.id) label.id = `${this.uid}-label`
        return label.id
      }
    }
    const labelledby = this.select.getAttribute("aria-labelledby")
    if (labelledby) return labelledby
    const ariaLabel = this.select.getAttribute("aria-label")
    if (!ariaLabel) return null
    const span = document.createElement("span")
    span.className = "sr-only"
    span.id = `${this.uid}-aria-label`
    span.textContent = ariaLabel
    this.element.appendChild(span)
    return span.id
  }

  buildTrigger() {
    const b = document.createElement("button")
    b.type = "button"
    b.className =
      "w-full h-[34px] px-3 rounded-md border border-stone-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 text-[13px] text-left " +
      "flex items-center justify-between gap-2 hover:border-stone-300 dark:hover:border-zinc-700 focus:outline-none " +
      "focus:border-indigo-600 dark:focus:border-indigo-400 focus:ring-2 focus:ring-indigo-100 dark:focus:ring-indigo-500/20"
    const valueId = `${this.uid}-value`
    // DOM (no innerHTML): il valore corrente lo scrive renderTrigger() via textContent → niente XSS.
    const value = document.createElement("span")
    value.dataset.label = ""
    value.id = valueId
    value.className = "truncate text-gray-400 dark:text-zinc-500"
    const chevron = icon("chevron-down", "text-gray-400 dark:text-zinc-500 text-[11px] shrink-0")
    if (this.prefixValue) {
      const prefix = document.createElement("span")
      prefix.className = "inline-flex items-center gap-1.5 text-gray-500 dark:text-zinc-400 shrink-0"
      if (this.prefixIconValue) {
        prefix.append(icon(this.prefixIconValue, "text-[11px]"))
      }
      prefix.append(document.createTextNode(this.prefixValue))
      value.classList.add("font-semibold", "mr-auto")
      b.classList.remove("justify-between")
      b.append(prefix)
    }
    b.append(value, chevron)
    // Disclosure: apre il listbox. aria-expanded segue apri/chiudi (sync in open/close).
    b.setAttribute("aria-haspopup", "listbox")
    b.setAttribute("aria-expanded", "false")
    b.setAttribute("aria-controls", this.listboxId)
    // Nome accessibile "<label> <valore corrente>"; senza label resta il contenuto (il valore).
    if (this.labelId) b.setAttribute("aria-labelledby", `${this.labelId} ${valueId}`)
    b.addEventListener("click", (e) => { e.preventDefault(); this.toggle() })
    b.addEventListener("keydown", (e) => this.onTriggerKeydown(e))
    return b
  }

  buildPanel() {
    const p = document.createElement("div")
    // z-30, non z-20: una barra sticky della pagina (la riga dei bottoni di salvataggio sta a z-20)
    // vincerebbe a parità di livello perché viene dopo nel DOM, e si mangerebbe le opzioni in fondo
    // alla tendina aperta — cliccabili solo scrollando. Una lista aperta sta sopra le barre; resta
    // sotto i livelli 40 e 50, riservati a overlay e modali.
    p.className =
      "absolute left-0 right-0 top-[38px] z-30 rounded-md border border-stone-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 py-1.5 hidden"
    const sw = document.createElement("div")
    sw.className = "px-2 pb-1.5"
    this.search = document.createElement("input")
    this.search.type = "text"
    this.search.placeholder = this.searchLabelValue
    this.search.className =
      "w-full h-8 px-2.5 rounded border border-stone-200 dark:border-zinc-800 text-[12.5px] focus:outline-none focus:border-indigo-600 dark:focus:border-indigo-400"
    // Il campo di ricerca È il combobox (dove va il focus da aperto e dove si naviga da tastiera).
    this.search.setAttribute("role", "combobox")
    this.search.setAttribute("aria-expanded", "false")
    this.search.setAttribute("aria-controls", this.listboxId)
    this.search.setAttribute("aria-autocomplete", "list")
    this.search.setAttribute("aria-activedescendant", "")
    this.search.setAttribute("autocomplete", "off")
    if (this.labelId) this.search.setAttribute("aria-labelledby", this.labelId)
    else this.search.setAttribute("aria-label", this.placeholderValue)
    this.search.addEventListener("input", () => this.filter())
    this.search.addEventListener("keydown", (e) => this.onSearchKeydown(e))
    sw.appendChild(this.search)
    this.list = document.createElement("div")
    this.list.className = "max-h-56 overflow-y-auto"
    this.list.id = this.listboxId
    this.list.setAttribute("role", "listbox")
    if (this.multipleValue) this.list.setAttribute("aria-multiselectable", "true")
    if (this.labelId) this.list.setAttribute("aria-labelledby", this.labelId)
    else this.list.setAttribute("aria-label", this.placeholderValue)
    p.appendChild(sw)
    p.appendChild(this.list)
    return p
  }

  renderList() {
    this.list.replaceChildren()
    this.options.forEach((opt, i) => {
      const row = document.createElement("button")
      row.type = "button"
      row.id = `${this.uid}-opt-${i}`
      row.tabIndex = -1
      // Parità col <select> nativo: hidden → riga non mostrata; disabled → riga visibile ma non
      // selezionabile. Un solo indice (i) per this.options/rows() SEMPRE — mai saltare la creazione
      // della riga (romperebbe l'allineamento posizionale usato da activeIndex/choose/visibleIndices).
      row.hidden = !!opt.hidden
      row.disabled = !!opt.disabled
      // Opzione ARIA: la navigazione è via aria-activedescendant sul combobox, la riga non è tabbabile.
      row.setAttribute("role", "option")
      row.setAttribute("aria-selected", opt.selected ? "true" : "false")
      if (opt.disabled) row.setAttribute("aria-disabled", "true")
      // disabled:opacity-50/disabled:cursor-not-allowed sono utility GIÀ compilate (stesse classi del
      // bottone "Riempi ora" in tickets/_form.html.erb) — qui solo applicate, mai introdotte ex-novo
      // da un .js (Tailwind non scansiona i .js, vedi commento in ui/picker_controller.js).
      row.className =
        "w-full text-left flex items-center gap-2 px-3 h-8 text-[12.5px] hover:bg-stone-50 dark:hover:bg-zinc-800 " +
        "disabled:opacity-50 disabled:cursor-not-allowed"
      const optionLabel = this.optionLabel(opt)
      row.dataset.label = optionLabel.toLowerCase()
      // CYRA-343: descrizione per-opzione (data-description, opt-in dal SelectComponent) resa come
      // seconda riga «in parole semplici» sotto la voce. items-start/py-1.5 ospitano le due righe e
      // tengono il check in alto; senza descrizione il ramo resta IDENTICO a prima (nessun impatto
      // sugli altri select). Le classi Tailwind sono già compilate in ERB (Tailwind non scansiona i .js).
      const description = opt.dataset.description
      // textContent (non innerHTML): label e descrizione sono testo → niente XSS.
      if (description) {
        row.classList.remove("items-center", "h-8")
        row.classList.add("items-start", "py-1.5")
        const textWrap = document.createElement("span")
        textWrap.className = "min-w-0 flex-1"
        const labelSpan = document.createElement("span")
        labelSpan.className = "block truncate"
        labelSpan.textContent = optionLabel
        const descSpan = document.createElement("span")
        descSpan.className = "block text-[11px] text-gray-500 dark:text-zinc-400 mt-0.5"
        descSpan.textContent = description
        textWrap.append(labelSpan, descSpan)
        row.appendChild(textWrap)
      } else {
        const span = document.createElement("span")
        span.className = "truncate"
        span.textContent = optionLabel
        row.appendChild(span)
      }
      if (opt.selected) {
        row.appendChild(icon("check", "text-indigo-600 dark:text-indigo-400 text-[11px] ml-auto"))
      }
      // Guardia esplicita oltre al nativo `disabled` (che già impedisce click/hover del browser):
      // difesa in profondità, zero costo, indipendente da nuance cross-browser sugli eventi mouse.
      row.addEventListener("click", (e) => { e.preventDefault(); if (!opt.disabled) this.choose(opt) })
      row.addEventListener("mousemove", () => { if (!opt.disabled) this.setActiveIndex(i) })
      this.list.appendChild(row)
    })
  }

  choose(opt) {
    if (this.multipleValue) {
      opt.selected = !opt.selected
    } else {
      this.options.forEach((o) => { o.selected = false })
      opt.selected = true
    }
    this.renderList()
    this.renderTrigger()
    if (this.multipleValue) {
      this.applyActive() // panel resta aperto: ripristina l'evidenza dopo il re-render
    } else {
      this.close()
      this.trigger.focus() // single: torna al trigger (contratto tastiera)
    }
    this.select.dispatchEvent(new Event("change", { bubbles: true }))
  }

  renderTrigger() {
    const selected = this.options.filter((o) => o.selected)
    const label = this.trigger.querySelector("[data-label]")
    if (selected.length === 0) {
      label.textContent = this.placeholderValue
      label.classList.add("text-gray-400", "dark:text-zinc-500")
      label.classList.remove("text-zinc-900", "dark:text-zinc-100")
    } else {
      const names = selected.map((o) => this.optionLabel(o))
      // summary (filtri): "Noun: a, b +N" (cap a 2 + contatore). Altrimenti (form): "a, b" / "N selected".
      const shown =
        names.length <= 2 ? names.join(", ") : `${names.slice(0, 2).join(", ")} +${names.length - 2}`
      if (this.summaryValue) {
        label.textContent = `${this.placeholderValue}: ${shown}`
      } else {
        label.textContent =
          names.length <= 2
            ? names.join(", ")
            : this.selectedLabelValue.replace("%{count}", names.length)
      }
      label.classList.remove("text-gray-400", "dark:text-zinc-500")
      label.classList.add("text-zinc-900", "dark:text-zinc-100")
    }
  }

  // include_blank senza testo deve comunque avere un affordance visibile nel widget arricchito.
  // Se invece l'option vuota ha un'etichetta esplicita (es. "Qualsiasi livello"), la preserva.
  optionLabel(opt) { return opt.textContent || this.placeholderValue || DEFAULT_PLACEHOLDER }

  // Ricalcola SOLO quali righe sono nascoste, da opt.hidden (dato) + query di ricerca corrente —
  // non tocca l'evidenza (activeIndex). this.rows()[i] ↔ this.options[i] sono sempre allineate
  // posizionalmente (renderList() crea una riga per OGNI opzione, mai saltata) → hidden-da-dato e
  // hidden-da-ricerca restano entrambe rispettate, anche dopo un re-render (sync()). Estratta da
  // filter() così sync() può riapplicarla SENZA il reset dell'evidenza che filter() fa in coda
  // (vedi sync() per il perché: choose() su multi-select dispatcha "change" ad ogni pick).
  applyHiddenState() {
    const q = this.search.value.toLowerCase()
    this.rows().forEach((row, i) => {
      const opt = this.options[i]
      const searchHidden = q !== "" && !row.dataset.label.includes(q)
      row.hidden = !!opt.hidden || searchHidden
    })
  }

  // Da input di ricerca (nuova query dell'utente) o apertura pannello: ricalcola le righe nascoste
  // E riporta l'evidenza alla prima opzione visibile (contratto tastiera — una ricerca nuova
  // riparte sempre dall'inizio). Il reset dell'evidenza vive SOLO qui — sync() lo evita apposta.
  filter() {
    this.applyHiddenState()
    this.setActiveIndex(this.firstVisibleIndex())
  }

  // --- Tastiera --------------------------------------------------------------

  onTriggerKeydown(e) {
    // Da chiuso, ArrowDown/Up aprono il pannello (Enter/Space aprono via click nativo del button).
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault()
      if (!this.isOpen) this.open()
    }
  }

  onSearchKeydown(e) {
    switch (e.key) {
      case "ArrowDown": e.preventDefault(); this.move(1); break
      case "ArrowUp": e.preventDefault(); this.move(-1); break
      case "Home": e.preventDefault(); this.setActiveIndex(this.firstVisibleIndex()); break
      case "End": e.preventDefault(); this.setActiveIndex(this.lastVisibleIndex()); break
      case "Enter": {
        e.preventDefault() // evita il submit del form filtri quando si sceglie da tastiera
        if (this.activeRow()) this.choose(this.options[this.activeIndex])
        break
      }
      case "Escape": e.preventDefault(); this.close(); this.trigger.focus(); break
      case "Tab": this.close(); break // lascia scorrere il focus, ma chiude il pannello
    }
  }

  // --- Opzione attiva (aria-activedescendant) --------------------------------

  rows() { return Array.from(this.list.children) }
  activeRow() { const r = this.rows()[this.activeIndex]; return r && !r.hidden && !r.disabled ? r : null }

  // disabled esclusa al pari di hidden: come un <option disabled> nativo, non è raggiungibile da
  // tastiera (native <select> salta le opzioni disabilitate durante la navigazione).
  visibleIndices() { return this.rows().map((r, i) => (r.hidden || r.disabled ? -1 : i)).filter((i) => i >= 0) }
  firstVisibleIndex() { const v = this.visibleIndices(); return v.length ? v[0] : -1 }
  lastVisibleIndex() { const v = this.visibleIndices(); return v.length ? v[v.length - 1] : -1 }

  move(dir) {
    const v = this.visibleIndices()
    if (!v.length) return
    const pos = v.indexOf(this.activeIndex)
    const next = pos === -1 ? (dir > 0 ? v[0] : v[v.length - 1]) : v[(pos + dir + v.length) % v.length]
    this.setActiveIndex(next)
  }

  setActiveIndex(i) {
    this.activeIndex = i
    this.applyActive()
  }

  applyActive() {
    const rows = this.rows()
    rows.forEach((r) => r.classList.remove(...HIGHLIGHT))
    const row = rows[this.activeIndex]
    if (row && !row.hidden && !row.disabled) {
      row.classList.add(...HIGHLIGHT)
      this.search.setAttribute("aria-activedescendant", row.id)
      this.revealRow(row)
    } else {
      this.search.setAttribute("aria-activedescendant", "")
    }
  }

  // Scrolls the list only: scrollIntoView would also scroll the page, and that closes the panel.
  revealRow(row) {
    const list = this.list.getBoundingClientRect()
    const box = row.getBoundingClientRect()
    if (box.top < list.top) this.list.scrollTop -= list.top - box.top
    else if (box.bottom > list.bottom) this.list.scrollTop += box.bottom - list.bottom
  }

  // --- Apertura/chiusura -----------------------------------------------------

  toggle() { this.isOpen ? this.close() : this.open() }

  // opened/closed (bubbles) alimentano ui--filter-bar (auto-submit dei filtri toolbar):
  // senza listener a monte non hanno effetti. La guardia in close() è necessaria perché
  // l'outside-click lo invoca a OGNI click del documento, anche a panel già chiuso.
  open() {
    // Out of the flow BEFORE it shows: an absolute panel would stretch its scroll box for a frame,
    // and that scroll would close it again.
    this.panel.style.position = "fixed"
    this.panel.classList.remove("hidden")
    this.search.value = ""
    this.filter()
    this.setActiveIndex(this.initialActiveIndex()) // apri sull'opzione selezionata, altrimenti la prima
    this.trigger.setAttribute("aria-expanded", "true")
    this.search.setAttribute("aria-expanded", "true")
    this.float()
    this.search.focus({ preventScroll: true })
    this.dispatch("opened")
  }

  // A scrolling ancestor (a dialog, the ticket side column) would cut the panel or stretch: it leaves
  // the flow (fixed, measured from the trigger) and opens upwards when there is no room below. Any
  // scroll outside the panel, or a resize, closes it, so it never drifts away from its trigger.
  float() {
    const rect = this.trigger.getBoundingClientRect()
    const below = window.innerHeight - rect.bottom
    const height = this.panel.offsetHeight
    const top = below < height + 8 && rect.top > below ? rect.top - height - 2 : rect.bottom + 2
    Object.assign(this.panel.style, { position: "fixed", left: `${rect.left}px`, right: "auto", top: `${Math.max(top, 8)}px`, width: `${rect.width}px` })
    // Choosing an option can scroll the hidden native select without moving the floating panel.
    this.onOutsideScroll = (event) => {
      if (event.target !== this.select && !this.panel.contains(event.target)) this.close()
    }
    requestAnimationFrame(() => {
      if (!this.isOpen) return
      document.addEventListener("scroll", this.onOutsideScroll, true)
      window.addEventListener("resize", this.onOutsideScroll)
    })
  }

  initialActiveIndex() {
    const selected = this.options.findIndex((o) => o.selected)
    const rows = this.rows()
    if (selected >= 0 && rows[selected] && !rows[selected].hidden && !rows[selected].disabled) return selected
    return this.firstVisibleIndex()
  }

  close() {
    if (!this.isOpen) return
    this.panel.classList.add("hidden")
    if (this.onOutsideScroll) {
      document.removeEventListener("scroll", this.onOutsideScroll, true)
      window.removeEventListener("resize", this.onOutsideScroll)
    }
    this.trigger.setAttribute("aria-expanded", "false")
    this.search.setAttribute("aria-expanded", "false")
    this.search.setAttribute("aria-activedescendant", "")
    this.activeIndex = -1
    this.dispatch("closed")
  }
}
