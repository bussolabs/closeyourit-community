import { Controller } from "@hotwired/stimulus"
import { icon } from "lib/icon"

// CYRA-902 — the mode picker inside the search field: a button plus a listbox (never a native select).
// Choosing a mode writes the hidden `semantic` field and makes the icon and the placeholder follow it.
export default class extends Controller {
  static targets = ["trigger", "menu", "value", "icon", "input"]

  connect() {
    this.outside = (e) => { if (!this.triggerTarget.contains(e.target) && !this.menuTarget.contains(e.target)) this.close() }
    this.escape = (e) => { if (e.key === "Escape" && !this.menuTarget.hidden) { this.close(); this.triggerTarget.focus() } }
    document.addEventListener("click", this.outside)
    document.addEventListener("keydown", this.escape)
  }

  disconnect() {
    document.removeEventListener("click", this.outside)
    document.removeEventListener("keydown", this.escape)
  }

  toggle() {
    this.menuTarget.hidden ? this.open() : this.close()
  }

  open() {
    this.menuTarget.hidden = false
    this.triggerTarget.setAttribute("aria-expanded", "true")
    this.menuTarget.querySelector("[aria-selected='true']")?.focus()
  }

  close() {
    this.menuTarget.hidden = true
    this.triggerTarget.setAttribute("aria-expanded", "false")
  }

  choose(event) {
    const option = event.currentTarget
    this.valueTarget.value = option.dataset.value
    this.menuTarget.querySelectorAll("[role='option']").forEach((item) => {
      const chosen = item === option
      item.setAttribute("aria-selected", String(chosen))
      item.querySelector("[data-check]").hidden = !chosen
    })
    this.swapIcon(option.dataset.icon)
    this.triggerTarget.title = option.dataset.label
    this.inputTarget.placeholder = option.dataset.placeholder
    this.close()
    this.inputTarget.focus()
  }

  // A new SVG for the chosen mode, with the old one's classes and target.
  swapIcon(name) {
    const current = this.iconTarget
    const next = icon(name)
    next.setAttribute("class", current.getAttribute("class"))
    next.setAttribute("data-ui--search-mode-target", "icon")
    current.replaceWith(next)
  }
}
