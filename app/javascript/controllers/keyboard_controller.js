import { Controller } from "@hotwired/stimulus"

// Controller GLOBALE della tastiera (CYRA-28): montato UNA volta nel layout member (sul wrapper
// .flex.h-screen) così il set UNIVERSALE scatta su ogni pagina. Fornisce anche l'help modal CONDIVISO
// (un solo <dialog>, centrato, reso dal layout) auto-popolato dal "registry":
//   - la parte UNIVERSALE è resa server-side dallo stesso helper che alimenta questa logica
//     (data-keyboard-nav-value) → doc e binding restano in sync;
//   - la parte "questa pagina" è raccolta a runtime dagli elementi [data-keyboard-doc] presenti,
//     così i controller per-pagina (board/occurrence/triage) documentano i loro tasti in modo
//     DICHIARATIVO, senza duplicare né un cheatsheet per pagina.
//
// Universali:
//   ?        apre l'help    (Shift+/ — nessun altro modifier)
//   /        focus ricerca  (primo [data-keyboard-search], se presente nella pagina)
//   n        nuovo          (clicca [data-keyboard-new], se presente nella pagina)
//   g <lett> naviga         (destinazioni sidebar visibili, da navValue)
//   Esc      chiude l'help
// Guard IDENTICI a quelli storici (keyboard_shortcuts_controller): ignora i modifier (meta/ctrl/alt)
// e la digitazione in campi editabili (INPUT/TEXTAREA/SELECT/contentEditable).
export default class extends Controller {
  static targets = [ "help", "pageSection", "pageList" ]
  static values = { nav: Array }

  connect() {
    this._onKeydown = this.handle.bind(this)
    window.addEventListener("keydown", this._onKeydown)
  }

  disconnect() {
    window.removeEventListener("keydown", this._onKeydown)
    this.#clearNavTimer()
  }

  handle(event) {
    if (event.metaKey || event.ctrlKey || event.altKey) return
    if (this.#typing(event.target)) { this.#disarmNav(); return }
    // Con un <dialog> modale aperto (l'help stesso o un dialog di conferma) gli universali NON devono
    // agire su elementi dietro il modale: l'interazione resta confinata al dialog. Esc lo chiude
    // nativamente; ? è idempotente (l'help è già aperto).
    if (this.#modalOpen()) { this.#disarmNav(); return }

    // Modo "g": la lettera successiva sceglie la destinazione (finestra breve, poi decade).
    if (this.awaitingNav) {
      this.#disarmNav()
      const dest = this.navValue.find((b) => b.key === event.key)
      if (dest) { event.preventDefault(); this.#visit(dest.url) }
      return
    }

    switch (event.key) {
      case "?": event.preventDefault(); this.openHelp(); break
      case "/": if (this.#focusSearch()) event.preventDefault(); break
      case "n": if (this.#clickNew()) event.preventDefault(); break
      case "g": if (this.navValue.length) this.#armNav(); break
      case "Escape": this.closeHelp(); break
      default: break
    }
  }

  // --- Help modal condiviso ---
  openHelp() {
    if (!this.hasHelpTarget || this.helpTarget.open) return
    this.#populatePage()
    this.helpTarget.showModal()
  }

  closeHelp() {
    if (this.hasHelpTarget && this.helpTarget.open) this.helpTarget.close()
  }

  // Chiude se il click cade sul <dialog> stesso (area backdrop), non sul contenuto interno.
  backdrop(event) {
    if (event.target === this.helpTarget) this.helpTarget.close()
  }

  // Raccoglie i [data-keyboard-doc] (JSON [{keys,label}]) presenti nella pagina e popola la sezione
  // "questa pagina". Sempre ricostruita all'apertura → riflette ESATTAMENTE i binding attivi ora.
  #populatePage() {
    if (!this.hasPageListTarget) return
    const rows = []
    this.element.querySelectorAll("[data-keyboard-doc]").forEach((el) => {
      let entries
      try { entries = JSON.parse(el.dataset.keyboardDoc) } catch (_) { return }
      if (!Array.isArray(entries)) return
      entries.forEach((e) => { if (e && e.keys && e.label) rows.push(this.#row(e.label, e.keys)) })
    })
    this.pageListTarget.replaceChildren(...rows)
    if (this.hasPageSectionTarget) this.pageSectionTarget.hidden = rows.length === 0
  }

  #row(label, keys) {
    const li = document.createElement("li")
    li.className = "flex items-center justify-between gap-4"
    const span = document.createElement("span")
    span.textContent = label
    const kbd = document.createElement("kbd")
    kbd.className = "font-mono text-[11px] bg-stone-100 dark:bg-zinc-800 border border-stone-200 dark:border-zinc-800 rounded px-1.5 py-0.5"
    kbd.textContent = keys
    li.append(span, kbd)
    return li
  }

  // --- Universali ---
  #focusSearch() {
    const el = this.element.querySelector("[data-keyboard-search]")
    if (!el) return false
    el.focus()
    if (typeof el.select === "function") el.select()
    return true
  }

  #clickNew() {
    const el = this.element.querySelector("[data-keyboard-new]")
    if (!el) return false
    el.click()
    return true
  }

  #visit(url) {
    if (window.Turbo) window.Turbo.visit(url)
    else window.location.assign(url)
  }

  #armNav() {
    this.awaitingNav = true
    this.#clearNavTimer()
    this._navTimer = setTimeout(() => { this.awaitingNav = false }, 1200)
  }

  #disarmNav() {
    this.awaitingNav = false
    this.#clearNavTimer()
  }

  #clearNavTimer() {
    if (this._navTimer) { clearTimeout(this._navTimer); this._navTimer = null }
  }

  #typing(el) {
    if (!el) return false
    return [ "INPUT", "TEXTAREA", "SELECT" ].includes(el.tagName) || el.isContentEditable
  }

  // Un qualsiasi <dialog> aperto (nel progetto sempre via showModal → modale) confina l'interazione:
  // gli universali si sospendono finché non viene chiuso.
  #modalOpen() {
    return document.querySelector("dialog[open]") !== null
  }
}
