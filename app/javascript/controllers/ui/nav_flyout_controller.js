import { Controller } from "@hotwired/stimulus"

// CYRA-909 — the compact sidebar hides a group's leaves: hover or focus on the group shows them in a
// popover beside the icon. Top layer, so the nav's overflow cannot clip it. Esc closes it.
export default class extends Controller {
  static targets = ["panel"]

  static HIDE_DELAY = 200

  disconnect() {
    this.closeAll()
  }

  enter(event) {
    clearTimeout(this.hideTimer)
    if (this.muted || !this.#compact()) return

    const panel = this.#panelOf(event.currentTarget)
    if (!panel || panel.matches(":popover-open")) return

    this.closeAll()
    panel.showPopover()
    this.#place(panel)
  }

  leave(event) {
    const panel = this.#panelOf(event.currentTarget)

    clearTimeout(this.hideTimer)
    this.hideTimer = setTimeout(() => this.#close(panel), this.constructor.HIDE_DELAY)
  }

  escape(event) {
    const panel = this.#panelOf(event.currentTarget)
    if (!panel?.matches(":popover-open")) return

    this.#close(panel)
    // Focus goes back to the group's link without reopening the flyout it just closed.
    this.muted = true
    event.currentTarget.querySelector("a")?.focus()
    this.muted = false
  }

  closeAll() {
    clearTimeout(this.hideTimer)
    this.panelTargets.forEach((panel) => this.#close(panel))
  }

  #close(panel) {
    if (panel?.matches(":popover-open")) panel.hidePopover()
  }

  #place(panel) {
    const link = panel.parentElement.querySelector("a").getBoundingClientRect()
    const maxTop = window.innerHeight - panel.offsetHeight - 8

    panel.style.left = `${this.element.getBoundingClientRect().right + 6}px`
    panel.style.top = `${Math.max(8, Math.min(link.top - 6, maxTop))}px`
  }

  #panelOf(group) {
    return this.panelTargets.find((panel) => group.contains(panel))
  }

  // Compact is a desktop-only state: the mobile drawer always shows the full tree.
  #compact() {
    return this.element.closest("[data-compact]") !== null && window.matchMedia("(min-width: 48rem)").matches
  }
}
