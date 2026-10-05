import { Controller } from "@hotwired/stimulus"

// CYRA-663 — lo stato iniziale NON arriva piu' da qui. Il server emetteva `inert` e
// `aria-hidden` sull'aside e solo syncForViewport() li toglieva su desktop: con Stimulus lento o
// rotto la sidebar restava visibile e morta, e in Valhalla non c'e' nemmeno la barra in basso come
// alternativa. Ora fuori dal drawer il pannello e' nascosto dal CSS (`max-md:invisible`), che non
// dipende da JavaScript: su desktop la sidebar e' viva anche se questo controller non parte mai.
//
// Drawer mobile accessibile: quando è chiuso esce dall'albero di focus (`inert`) e da quello
// semantico (`aria-hidden`). Quando si apre trattiene il focus, si chiude con Escape e restituisce
// il focus al controllo che lo ha aperto. Da md in su la sidebar torna una normale navigazione.
export default class extends Controller {
  static targets = ["panel", "overlay", "toggle"]

  connect() {
    this._open = false
    this.onKeydown = (event) => this.handleKeydown(event)
    this.onResize = () => this.syncForViewport()
    document.addEventListener("keydown", this.onKeydown)
    window.addEventListener("resize", this.onResize)
    this.syncForViewport()
  }

  disconnect() {
    document.removeEventListener("keydown", this.onKeydown)
    window.removeEventListener("resize", this.onResize)
  }

  toggle(event) { this.isOpen ? this.close() : this.open(event) }

  open(event) {
    if (!this.isMobile) return

    this._open = true
    this.returnFocusTarget = event?.currentTarget || this.toggleTargets[0]
    this.panelTarget.classList.remove("-translate-x-full", "max-md:invisible")
    // Un elemento con `visibility: hidden` NON accetta il focus. Togliere la classe non basta:
    // senza forzare il ricalcolo, il focus qui sotto cadrebbe nel vuoto perche' per il browser
    // il pannello e' ancora nascosto. Lo prende lo spec di sistema del drawer, non gli unitari.
    void this.panelTarget.offsetWidth
    this.panelTarget.removeAttribute("inert")
    this.panelTarget.setAttribute("aria-hidden", "false")
    if (this.hasOverlayTarget) this.overlayTarget.hidden = false
    this.setExpanded(true)
    // Il focus va dato SUBITO, non al frame successivo: il reflow qui sopra ha gia' reso il
    // pannello visibile e quindi focusabile, e rimandare lascia una finestra in cui il drawer
    // e' aperto ma il focus sta ancora fuori.
    this.focusableElements[0]?.focus()
  }

  close() {
    const wasOpen = this.isOpen
    this._open = false
    this.panelTarget.classList.add("-translate-x-full", "max-md:invisible")
    if (this.hasOverlayTarget) this.overlayTarget.hidden = true
    this.setExpanded(false)

    if (this.isMobile) {
      this.panelTarget.setAttribute("inert", "")
      this.panelTarget.setAttribute("aria-hidden", "true")
    } else {
      this.panelTarget.removeAttribute("inert")
      this.panelTarget.setAttribute("aria-hidden", "false")
    }

    if (wasOpen && this.returnFocusTarget?.isConnected) this.returnFocusTarget.focus()
  }

  handleKeydown(event) {
    if (!this.isOpen || !this.isMobile) return

    if (event.key === "Escape") {
      event.preventDefault()
      this.close()
      return
    }

    if (event.key !== "Tab") return

    const focusable = this.focusableElements
    if (focusable.length === 0) {
      event.preventDefault()
      return
    }

    const first = focusable[0]
    const last = focusable[focusable.length - 1]
    const outside = !this.panelTarget.contains(document.activeElement)

    if (event.shiftKey && (document.activeElement === first || outside)) {
      event.preventDefault()
      last.focus()
    } else if (!event.shiftKey && (document.activeElement === last || outside)) {
      event.preventDefault()
      first.focus()
    }
  }

  syncForViewport() {
    if (this.isMobile) {
      if (this.isOpen) {
        this.panelTarget.classList.remove("max-md:invisible")
        this.panelTarget.removeAttribute("inert")
        this.panelTarget.setAttribute("aria-hidden", "false")
      } else {
        this.panelTarget.classList.add("-translate-x-full", "max-md:invisible")
        this.panelTarget.setAttribute("inert", "")
        this.panelTarget.setAttribute("aria-hidden", "true")
        if (this.hasOverlayTarget) this.overlayTarget.hidden = true
        this.setExpanded(false)
      }
      return
    }

    // CYRA-663 — passando a desktop il drawer si chiude: se era aperto il focus stava DENTRO il
    // pannello, e il bottone che lo apriva e' `md:hidden`, cioe' sparisce. Senza restituire il
    // focus a qualcosa di vivo si finisce sul body, e chi naviga da tastiera riparte da capo.
    const eraAperto = this.isOpen
    this._open = false
    this.panelTarget.classList.add("-translate-x-full", "max-md:invisible")
    this.panelTarget.removeAttribute("inert")
    this.panelTarget.setAttribute("aria-hidden", "false")
    if (this.hasOverlayTarget) this.overlayTarget.hidden = true
    this.setExpanded(false)
    if (eraAperto) this.element.querySelector("#main-content")?.focus()
  }

  get isOpen() { return this._open }

  get isMobile() { return window.innerWidth < 768 }

  get focusableElements() {
    const selector = [
      "a[href]", "button:not([disabled])", "summary", "input:not([disabled])",
      "select:not([disabled])", "textarea:not([disabled])", "[tabindex]:not([tabindex='-1'])"
    ].join(",")

    return Array.from(this.panelTarget.querySelectorAll(selector)).filter((element) => {
      return !element.hidden && element.getClientRects().length > 0
    })
  }

  setExpanded(open) {
    this.toggleTargets.forEach((toggle) => toggle.setAttribute("aria-expanded", String(open)))
  }
}
