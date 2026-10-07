import { Controller } from "@hotwired/stimulus"

// DESIGN.md C42 — the header row stays in view while the page scrolls down a long table. A sticky
// <thead> cannot do it: it sticks to the nearest overflow box, which is the table's own sideways
// scroller (or a panel with overflow hidden). Here the header cells are shifted down instead, by how
// far the table top has gone under the page header (`--page-header-h`, published by ui--page-header).
export default class extends Controller {
  connect() {
    this.page = this.#scrollParent()
    this.source = this.page ?? window
    this.source.addEventListener("scroll", this.schedule, { passive: true })
    this.resizer = new ResizeObserver(this.schedule)
    this.resizer.observe(this.element)
    this.schedule()
  }

  disconnect() {
    this.source?.removeEventListener("scroll", this.schedule)
    this.resizer?.disconnect()
    if (this.frame) cancelAnimationFrame(this.frame)
    this.#shift(0)
  }

  schedule = () => {
    if (this.frame) return

    this.frame = requestAnimationFrame(() => {
      this.frame = null
      this.update()
    })
  }

  update() {
    const head = this.element.tHead
    // Below 768px a stacked table shows cards and hides its header: nothing to keep in view.
    if (!head || head.offsetHeight === 0) return this.#shift(0)

    const table = this.element.getBoundingClientRect()
    const room = Math.max(table.height - head.offsetHeight, 0)
    this.#shift(Math.min(Math.max(this.#stickLine() - table.top, 0), room))
  }

  // Where the header must stop: right under the page header, or the top of the scrolling box.
  #stickLine() {
    if (!this.page) return 0

    // Only the box ui--page-header writes to: an inner scroller inherits the value, but the page header
    // is not inside it, and the header row was pushed over the rows (C42).
    const headerHeight = parseFloat(this.page.style.getPropertyValue("--page-header-h")) || 0
    return this.page.getBoundingClientRect().top + headerHeight
  }

  #shift(px) {
    this.element.toggleAttribute("data-head-shifted", px > 0)
    this.element.style.setProperty("--ui-head-shift", `${px}px`)
  }

  // The box that scrolls the page, skipping the table's own sideways scroller.
  #scrollParent() {
    const start = this.element.closest("[data-ui--scroll-hint-target='scroller']") ?? this.element
    for (let el = start.parentElement; el; el = el.parentElement) {
      if (/(auto|scroll)/.test(getComputedStyle(el).overflowY)) return el
    }
    return null
  }
}
