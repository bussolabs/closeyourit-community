import { Controller } from "@hotwired/stimulus"

// The stack of floating notices (shared/_floating_notices) sits over the bottom of the content.
// The part of the page that scrolls keeps room at its end as tall as the stack, so its last rows and
// controls can always be scrolled out from under it; a closed notice gives the room back. A page that
// does not scroll keeps its layout: its last panel already sits on the frame (DESIGN.md E22). CYRA-1105
export default class extends Controller {
  connect() {
    this.main = document.getElementById("main-content")
    if (!this.main) return

    this.observer = new ResizeObserver(() => this.reserve())
    this.observer.observe(this.element)
    this.reserve()
  }

  disconnect() {
    this.observer?.disconnect()
    this.release()
  }

  reserve() {
    this.release()
    const height = this.element.getBoundingClientRect().height
    if (height === 0) return

    const scroller = this.scroller()
    if (!scroller) return

    const base = parseFloat(getComputedStyle(scroller).paddingBottom) || 0
    const gap = scroller.getBoundingClientRect().bottom - this.element.getBoundingClientRect().bottom
    scroller.style.paddingBottom = `${Math.max(base, height + Math.max(gap, 0) + 16)}px`
    this.target = scroller
  }

  release() {
    if (this.target) this.target.style.paddingBottom = ""
    this.target = null
  }

  // A scrolling column of the page (data-panel-edge) first, then the content itself.
  scroller() {
    const scrolls = (el) => el.scrollHeight > el.clientHeight + 1
    const column = [...this.main.querySelectorAll("[data-panel-edge]")]
      .find((el) => /auto|scroll/.test(getComputedStyle(el).overflowY) && scrolls(el))
    if (column) return column
    return scrolls(this.main) ? this.main : null
  }
}
