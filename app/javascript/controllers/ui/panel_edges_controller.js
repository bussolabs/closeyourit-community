import { Controller } from "@hotwired/stimulus"

// DESIGN.md T1 — marks the sides of each outermost panel that touch the frame (`data-flush`), so CSS
// squares only the corners on those sides. The edge is the frame itself, or the section list of the
// Administration pages (`data-panel-edge`). On a phone the page keeps its padding: nothing touches.
// The element must be positioned (`relative`): offsets are summed up to it, and an unpositioned one is
// skipped by `offsetParent`, so every panel would measure from an outer box and none would touch.
const PANELS = ":is(.rounded-lg, .rounded-xl).border:not(:is(.rounded-lg, .rounded-xl).border *, dialog, .fixed)"
// Panels reach 1px past the frame, which clips them.
const TOLERANCE = 1.5

export default class extends Controller {
  connect() {
    this.schedule = this.schedule.bind(this)
    this.resizeObserver = new ResizeObserver(this.schedule)
    this.resizeObserver.observe(this.element)
    // Added or removed nodes, and panels shown or hidden (a tab switch): never every attribute, which
    // would wake up on our own `data-flush`. A hidden panel is skipped, so showing it must measure again.
    this.mutationObserver = new MutationObserver(this.schedule)
    this.mutationObserver.observe(this.element, { childList: true, subtree: true, attributes: true,
                                                  attributeFilter: ["hidden"] })
    this.schedule()
  }

  disconnect() {
    this.resizeObserver.disconnect()
    this.mutationObserver.disconnect()
    clearTimeout(this.timer)
  }

  // A timer, not an animation frame: frames pause in a background tab and the corners would wait.
  schedule() {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.measure())
  }

  measure() {
    this.#fill()
    this.#foot()
    this.element.querySelectorAll(PANELS).forEach((panel) => {
      if (!panel.offsetParent) return
      const edge = panel.closest("[data-panel-edge]") || this.element
      const [x, y] = this.#offset(panel, edge)
      const sides = []
      if (y <= TOLERANCE) sides.push("top")
      if (x + panel.offsetWidth >= edge.clientWidth - TOLERANCE) sides.push("right")
      if (y + panel.offsetHeight >= edge.scrollHeight - TOLERANCE) sides.push("bottom")
      if (x <= TOLERANCE) sides.push("left")
      const value = sides.join(" ")
      if (panel.dataset.flush !== value) panel.dataset.flush = value
    })
  }

  // DESIGN.md E24 — a page-level empty state (`data-empty-fill`) grows until its panel reaches the bottom
  // of the frame. Only when the page fits without scrolling and that panel is the lowest thing on it.
  // The panel then ends the page: its bottom margin goes (a hidden dialog after it is not a sibling to
  // keep a gap from), or the page would scroll by that gap.
  #fill() {
    const fills = [...this.element.querySelectorAll("[data-empty-fill]")].filter((el) => el.offsetParent)
      .map((el) => [el, el.closest(PANELS) || el])
    fills.forEach(([el, panel]) => {
      el.style.minHeight = ""
      panel.style.marginBottom = ""
    })
    fills.forEach(([el, panel]) => {
      const scroller = this.#scroller(el)
      if (scroller.scrollHeight > scroller.clientHeight + TOLERANCE) return
      const bottom = panel.getBoundingClientRect().bottom
      const lowest = Math.max(...[...scroller.querySelectorAll(PANELS)]
        .filter((other) => other.offsetParent).map((other) => other.getBoundingClientRect().bottom), bottom)
      if (bottom < lowest - TOLERANCE) return
      const padding = parseFloat(getComputedStyle(scroller).paddingBottom) || 0
      const extra = scroller.getBoundingClientRect().bottom - padding - bottom
      if (extra <= TOLERANCE) return
      el.style.minHeight = `${el.offsetHeight + extra}px`
      panel.style.marginBottom = "0px"
    })
  }

  // DESIGN.md E22 — the panel closing the page (`data-page-foot`) sits on the bottom of the frame: on a
  // page shorter than the frame it is pushed down by the space left under it.
  #foot() {
    const foot = [...this.element.querySelectorAll("[data-page-foot]")].find((el) => el.offsetParent)
    if (!foot) return
    const panel = foot.closest(PANELS) || foot
    panel.style.marginTop = ""
    panel.style.marginBottom = ""
    const scroller = this.#scroller(panel)
    if (scroller.scrollHeight > scroller.clientHeight + TOLERANCE) return
    const padding = parseFloat(getComputedStyle(scroller).paddingBottom) || 0
    const gap = () => scroller.getBoundingClientRect().bottom - padding - panel.getBoundingClientRect().bottom
    if (gap() <= TOLERANCE) return
    panel.style.marginBottom = "0px"
    // Twice: dropping the bottom margin can move the panel, so the first push may fall short.
    for (let pass = 0; pass < 2 && gap() > TOLERANCE; pass++) {
      panel.style.marginTop = `${(parseFloat(getComputedStyle(panel).marginTop) || 0) + gap()}px`
    }
  }

  // The page scrolls in the frame, or in the page column of a side shell on wide screens. Never a
  // table wrapper: `overflow-x-auto` alone already computes `overflow-y: auto`.
  #scroller(element) {
    const column = element.closest("[data-panel-edge]")
    return column && /auto|scroll/.test(getComputedStyle(column).overflowY) ? column : this.element
  }

  // Layout offsets, not the on-screen box: a stuck sticky header still sits at the top of the page.
  #offset(element, edge) {
    const [ex, ey] = this.#position(element)
    const [rx, ry] = edge === this.element ? [0, 0] : this.#position(edge)
    return [ex - rx, ey - ry]
  }

  #position(element) {
    let x = 0
    let y = 0
    for (let node = element; node && node !== this.element; node = node.offsetParent) {
      x += node.offsetLeft
      y += node.offsetTop
    }
    return [x, y]
  }
}
