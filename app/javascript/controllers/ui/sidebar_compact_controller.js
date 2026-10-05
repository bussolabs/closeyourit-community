import { Controller } from "@hotwired/stimulus"

// CYRA-903 — narrows the desktop sidebar to its icons. The choice lives in a cookie, not in
// localStorage, so the server renders the right width on the next page without a flash.
// In compact mode the labels are visually hidden: the `title` on each row gives them back on hover.
export default class extends Controller {
  static targets = ["toggle", "label"]

  static COOKIE = "sidebar_compact"

  connect() {
    this.#apply(this.element.hasAttribute("data-compact"))
  }

  toggle() {
    const compact = !this.element.hasAttribute("data-compact")

    this.element.toggleAttribute("data-compact", compact)
    document.cookie = `${this.constructor.COOKIE}=${compact ? "1" : "0"}; path=/; max-age=31536000; SameSite=Lax`
    this.#apply(compact)
  }

  #apply(compact) {
    this.element.querySelectorAll("[data-nav-label]").forEach((link) => {
      // A group's flyout already shows its name (CYRA-909): a title would sit on top of it.
      if (compact && !link.hasAttribute("data-nav-flyout")) link.title = link.dataset.navLabel
      else link.removeAttribute("title")
    })

    if (!this.hasToggleTarget) return

    const label = compact ? this.toggleTarget.dataset.expandLabel : this.toggleTarget.dataset.collapseLabel
    if (this.hasLabelTarget) this.labelTarget.textContent = label
  }
}
