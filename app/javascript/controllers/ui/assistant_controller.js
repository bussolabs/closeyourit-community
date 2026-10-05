import { Controller } from "@hotwired/stimulus"

const STORAGE_KEY = "assistant-dock"

// Right-hand column of the help assistant: it narrows the page, never covers it. Handles open/close
// and Esc, the body load on first opening (with its outcome), Enter to send, composer auto-grow,
// clearing after send and autoscroll when new bubbles arrive.
export default class extends Controller {
  static targets = ["panel", "frame", "error"]
  static values = { url: String, timeout: { type: Number, default: 8000 } }

  // The frame is replaced as a whole when a conversation is created, so its listeners follow the
  // target instead of being bound once: they are defined here, before any target connects.
  initialize() {
    // Il frame racconta il proprio esito su di sé: corpo arrivato (frame-load), risposta che non
    // contiene il pannello (frame-missing), richiesta caduta (fetch-request-error).
    this._onFrameLoad = () => this._loaded()
    this._onFrameFail = (event) => {
      // Senza preventDefault il fallback di Turbo su frame-missing porterebbe l'utente FUORI dalla
      // pagina in cui si trova, solo perché il pannello non si è caricato.
      event.preventDefault()
      this._failed()
    }
  }

  frameTargetConnected(frame) {
    frame.addEventListener("turbo:frame-load", this._onFrameLoad)
    frame.addEventListener("turbo:frame-missing", this._onFrameFail)
    frame.addEventListener("turbo:fetch-request-error", this._onFrameFail)
  }

  frameTargetDisconnected(frame) {
    frame.removeEventListener("turbo:frame-load", this._onFrameLoad)
    frame.removeEventListener("turbo:frame-missing", this._onFrameFail)
    frame.removeEventListener("turbo:fetch-request-error", this._onFrameFail)
  }

  connect() {
    this._onKeydown = (event) => { if (event.key === "Escape" && this.isOpen) this.close() }
    document.addEventListener("keydown", this._onKeydown)
    // The trigger sits in the topbar, outside this element, and the topbar is redrawn on every visit.
    // A project page carries its own trigger: it opens the column on that project's conversation.
    this._onClick = (event) => {
      const project = event.target.closest("[data-assistant-project-url]")
      if (project) this.openOn(project.dataset.assistantProjectUrl)
      else if (event.target.closest("[data-assistant-trigger]")) this.toggle()
    }
    if (this.hasPanelTarget) document.addEventListener("click", this._onClick)

    // Reconnects after every Turbo visit (permanent element) and after a full reload: the fresh
    // topbar learns the state, and an open column stays open.
    if (this.hasPanelTarget && !this.isOpen && this._remembered()) this.open()
    else this._syncTriggers()
  }

  disconnect() {
    document.removeEventListener("keydown", this._onKeydown)
    document.removeEventListener("click", this._onClick)
    clearTimeout(this._timer)
    this._observer?.disconnect()
    this._observer = null
  }

  // The conversation page reuses this controller for its composer only: there is no panel there.
  get isOpen() { return this.hasPanelTarget && !this.panelTarget.hidden }

  toggle() { this.isOpen ? this.close() : this.open() }

  open() {
    this.panelTarget.hidden = false
    this._remember(true)
    this._syncTriggers()
    this._load()
    this._observe()
    requestAnimationFrame(() => this._input()?.focus())
  }

  close() {
    this.panelTarget.hidden = true
    this._remember(false)
    this._syncTriggers()
  }

  // Opens the column on a project's panel address, replacing what was loaded. The address stays
  // the one to reload (retry, a spoken message) until the page is loaded again.
  openOn(url) {
    this._projectUrl = url
    this._load({ force: true })
    this.open()
  }

  // Pulsante del messaggio di errore: rifà la richiesta da capo.
  retry() { this._load({ force: true }) }

  // Chip di suggerimento → precompila il campo.
  suggest(event) {
    const input = this._input()
    if (!input) return
    input.value = event.params.suggestion
    input.focus()
    this._grow(input)
  }

  // "Correct and resend": the transcript goes back into the composer, marked as a correction so
  // the server discards the cards that answered the misheard sentence (CYRA-908).
  correct(event) {
    const input = this._input()
    if (!input) return
    input.value = event.params.text
    this._correction().value = event.params.messageId
    input.focus()
    this._grow(input)
  }

  // After a spoken message: open the panel on fresh content, since the bubble may belong to a
  // conversation the loaded frame is not showing (CYRA-908).
  openFresh() {
    if (this.hasFrameTarget && this.frameTarget.getAttribute("src")) this._load({ force: true })
    if (this.hasPanelTarget) this.open()
  }

  grow(event) { this._grow(event.target) }

  // Enter invia; Shift+Enter va a capo.
  submitOnEnter(event) {
    if (event.shiftKey) return
    event.preventDefault()
    event.target.form?.requestSubmit()
  }

  // Svuota il composer dopo un invio riuscito (le bolle arrivano via broadcast).
  reset(event) {
    if (event.detail?.success === false) return
    const input = this._input()
    if (!input) return
    input.value = ""
    this._correction().value = ""
    this._grow(input)
  }

  // --- interni ---

  _syncTriggers() {
    document.querySelectorAll("[data-assistant-trigger]").forEach((trigger) => {
      trigger.setAttribute("aria-expanded", String(this.isOpen))
    })
  }

  _remembered() {
    try { return sessionStorage.getItem(STORAGE_KEY) === "open" } catch { return false }
  }

  _remember(open) {
    try { open ? sessionStorage.setItem(STORAGE_KEY, "open") : sessionStorage.removeItem(STORAGE_KEY) } catch {}
  }

  // Carica il corpo del pannello. `src` si imposta QUI e non nel markup: il frame vive dentro un
  // contenitore hidden, quindi non "appare" mai e loading="lazy" non scatterebbe mai (CYRA-558).
  // Fuori dall'apertura non parte niente: la pagina resta leggera come con il caricamento pigro.
  _load({ force = false } = {}) {
    const url = this._projectUrl || this.urlValue
    if (!this.hasFrameTarget || !url) return
    if (this.frameTarget.getAttribute("src") && !force) return

    this._loading()
    this.frameTarget.removeAttribute("src")
    this.frameTarget.setAttribute("src", url)
    clearTimeout(this._timer)
    // Rete di sicurezza: una richiesta che non torna né bene né male non emette alcun evento, e senza
    // questo l'attesa finirebbe di nuovo sul cerchietto che gira all'infinito.
    this._timer = setTimeout(() => this._failed(), this.timeoutValue)
  }

  _loading() {
    if (this.hasErrorTarget) this.errorTarget.hidden = true
    if (this.hasFrameTarget) this.frameTarget.hidden = false
  }

  _loaded() {
    clearTimeout(this._timer)
    // Anche se il corpo arriva DOPO il messaggio di errore (richiesta lenta, non persa), il pannello
    // si riempie e l'errore sparisce da sé: chi aspettava non deve premere niente.
    this._loading()
    if (this.isOpen) requestAnimationFrame(() => this._input()?.focus())
    this._scrollToBottom()
  }

  _failed() {
    clearTimeout(this._timer)
    if (this.hasFrameTarget) this.frameTarget.hidden = true
    if (this.hasErrorTarget) this.errorTarget.hidden = false
  }

  _input() {
    return this.element.querySelector("[data-ui--assistant-target='input']")
  }

  // The field lives inside the frame, so it is looked up like the input, not declared as a target.
  _correction() {
    return this.element.querySelector("[data-ui--assistant-target='correction']") || { value: "" }
  }

  _grow(el) {
    if (!el) return
    el.style.height = "auto"
    el.style.height = `${Math.min(el.scrollHeight, 120)}px`
  }

  // Osserva l'intero pannello: cattura sia il caricamento del frame sia le bolle appese via
  // broadcast, e tiene la timeline scrollata in fondo.
  _observe() {
    if (this._observer) { this._scrollToBottom(); return }
    this._observer = new MutationObserver(() => this._scrollToBottom())
    this._observer.observe(this.panelTarget, { childList: true, subtree: true, characterData: true })
  }

  _scrollToBottom() {
    const scroller = this.panelTarget.querySelector("[data-ui--assistant-target='scroll']")
    if (scroller) scroller.scrollTop = scroller.scrollHeight
  }
}
