import { Controller } from "@hotwired/stimulus"

// CYRA-935 — the Support button slides the whole page up and shows the support screen underneath.
// The page is hidden once it is out of sight; the message is kept as a draft until it is sent.
const DRAFT_KEY = "support-draft"
const SLIDE = { duration: 450, easing: "cubic-bezier(.3,.7,.2,1)", fill: "forwards" }

export default class extends Controller {
  static targets = ["page", "screen", "body", "field"]
  static values = { identity: String }

  get draftKey() { return `${DRAFT_KEY}:${this.identityValue}` }

  bodyTargetConnected(field) {
    if (!field.value) field.value = this.#draft()
  }

  open() {
    if (!this.hasScreenTarget || !this.screenTarget.hidden) return
    this.#describe()
    this.screenTarget.hidden = false
    this.#slide(["translateY(0)", "translateY(-100%)"], () => {
      this.pageTarget.hidden = true
      if (this.hasBodyTarget) this.bodyTarget.focus({ preventScroll: true })
    })
  }

  close() {
    if (!this.hasScreenTarget || this.screenTarget.hidden) return
    this.pageTarget.hidden = false
    this.#slide(["translateY(-100%)", "translateY(0)"], () => {
      this.screenTarget.hidden = true
      // No transform left behind: it would become the containing block of the fixed bars.
      this.pageTarget.getAnimations().forEach((animation) => animation.cancel())
    })
  }

  closeOnEscape(event) {
    // While dictating, Esc belongs to the microphone.
    if (this.hasScreenTarget && this.screenTarget.querySelector("[data-ui--voice-inline-target='waves']:not([hidden])")) return
    this.close()
  }

  saveDraft() {
    if (!this.hasIdentityValue) return
    try { sessionStorage.setItem(this.draftKey, this.bodyTarget.value) } catch { /* storage off: the field still holds it */ }
  }

  submitted(event) {
    if (!event.detail.success) return
    try { sessionStorage.removeItem(this.draftKey) } catch { /* nothing to clear */ }
  }

  #draft() {
    if (!this.hasIdentityValue) return ""
    try {
      sessionStorage.removeItem(DRAFT_KEY)
      return sessionStorage.getItem(this.draftKey) || ""
    } catch { return "" }
  }

  // What only the browser knows: the page it was on, its window, its clock.
  #describe() {
    const details = {
      page: `${location.pathname}${location.search}`,
      page_title: document.title,
      window: `${window.innerWidth} × ${window.innerHeight}`,
      theme: document.documentElement.classList.contains("dark") ? "dark" : "light",
      timezone: Intl.DateTimeFormat().resolvedOptions().timeZone || ""
    }
    this.fieldTargets.forEach((field) => { field.value = details[field.dataset.key] || "" })
    this.#show("page", details.page)
    this.#show("page_title", details.page_title)
    this.#show("window", details.window)
    this.#show("time", `${new Date().toLocaleString()} ${details.timezone}`)
  }

  #show(name, text) {
    const target = this.screenTarget.querySelector(`[data-support-detail="${name}"]`)
    if (target) target.textContent = text
  }

  #slide(frames, done) {
    const page = this.pageTarget
    page.getAnimations().forEach((animation) => animation.cancel())
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return done()
    page.animate(frames.map((transform) => ({ transform })), SLIDE).finished.then(done).catch(() => {})
  }
}
