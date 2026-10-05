import { Controller } from "@hotwired/stimulus"

// DESIGN.md B25 — the page header collapses to title, actions, tabs and counts.
// `data-pinned` is the person's choice from the toggle, saved on the account for every page;
// scrolling the page collapses it too, without saving anything. `data-collapsed` drives the look.
export default class extends Controller {
  static targets = ["toggle"]
  static values = { url: String }
  static ROOM = 120

  connect() {
    this.scroller = this.#scrollParent()
    this.scrolled = false
    this.onScroll = this.onScroll.bind(this)
    this.scroller?.addEventListener("scroll", this.onScroll, { passive: true })
    // Anything else that sticks while the page scrolls (a section menu, a save bar) must stop below the
    // header, not under it: the header's live height is published on the scroller for their `top`.
    this.resizer = new ResizeObserver(() => this.#publishHeight())
    this.resizer.observe(this.element)
    this.#render()
  }

  disconnect() {
    this.scroller?.removeEventListener("scroll", this.onScroll)
    this.resizer?.disconnect()
    this.scroller?.style.removeProperty("--page-header-h")
  }

  toggle() {
    if (this.#collapsed()) {
      // Opening a header the scroll collapsed is a choice too: it stays open until the page is back on top.
      this.scrolled = false
      this.held = true
      this.#pin(false)
    } else {
      this.#pin(true)
    }
    this.#render()
  }

  onScroll() {
    const top = this.scroller.scrollTop
    if (top <= 4) this.held = false
    // Collapsing shortens the page by up to ~95px and the browser shifts the scroll to keep the content
    // still. Starting past that distance keeps the page off the top afterwards, so the header cannot
    // flicker open and shut; it opens again only back at the top.
    const room = this.scroller.scrollHeight - this.scroller.clientHeight
    const next = !this.held && top > this.constructor.ROOM && room > this.constructor.ROOM
    if (next === this.scrolled || (!next && top > 4)) return

    this.scrolled = next
    this.#render()
  }

  #pin(pinned) {
    if (pinned === this.element.hasAttribute("data-pinned")) return

    this.element.toggleAttribute("data-pinned", pinned)
    const body = new FormData()
    body.append("compact", pinned ? "1" : "0")
    // Only a preference: a failed save must not undo the gesture.
    fetch(this.urlValue, { method: "PATCH", body, headers: { "X-CSRF-Token": this.#csrf() } }).catch(() => {})
  }

  #collapsed() {
    return this.element.hasAttribute("data-pinned") || this.scrolled
  }

  #render() {
    const collapsed = this.#collapsed()
    this.element.toggleAttribute("data-collapsed", collapsed)
    if (!this.hasToggleTarget) return

    const label = collapsed ? this.toggleTarget.dataset.expandLabel : this.toggleTarget.dataset.collapseLabel
    this.toggleTarget.setAttribute("aria-expanded", String(!collapsed))
    this.toggleTarget.setAttribute("aria-label", label)
    this.toggleTarget.title = label
  }

  // The box that scrolls the page: the frame's <main>, or the Administration column on wide screens.
  #scrollParent() {
    for (let el = this.element.parentElement; el; el = el.parentElement) {
      if (/(auto|scroll)/.test(getComputedStyle(el).overflowY)) return el
    }
    return null
  }

  #publishHeight() {
    this.scroller?.style.setProperty("--page-header-h", `${this.element.offsetHeight}px`)
  }

  #csrf() {
    return document.querySelector("meta[name='csrf-token']")?.content
  }
}
