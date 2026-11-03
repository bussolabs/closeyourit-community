import { Controller } from "@hotwired/stimulus"

// One panel at a time, picked from a side menu of `#anchor` links. The address keeps the open panel, so a
// reload or a shared link opens the same one; without a fragment, `initial` is the panel the server wants
// open (the one just saved, or a save that failed). Without JS nothing is hidden and the links scroll to
// their panel as plain anchors.
// A link from the quick search names the section to point out with `?highlight=` (CYRA-1145).
const HIGHLIGHT = ["rounded-lg", "ring-2", "ring-indigo-600"]
const HIGHLIGHT_MS = 2500

export default class extends Controller {
  static targets = ["panel", "link"]
  static values = { initial: String }
  static classes = ["active", "idle", "iconActive", "iconIdle"]

  connect() {
    this.onHashChange = () => this.#show(this.#anchorFromHash())
    window.addEventListener("hashchange", this.onHashChange)
    this.#show(this.#anchorFromHash() || this.initialValue)
    this.#highlight(new URLSearchParams(location.search).get("highlight"))
  }

  disconnect() {
    window.removeEventListener("hashchange", this.onHashChange)
    clearTimeout(this.highlightTimer)
  }

  open(event) {
    event.preventDefault()
    const anchor = event.currentTarget.hash.slice(1)
    history.replaceState(history.state, "", `${location.pathname}#${anchor}`)
    this.#show(anchor)
    this.element.closest("main")?.scrollTo({ top: 0 })
  }

  #highlight(anchor) {
    const panel = this.panelTargets.find((candidate) => candidate.dataset.anchor === anchor)
    if (!panel || panel.hidden) return

    panel.classList.add(...HIGHLIGHT)
    panel.dataset.highlighted = "true"
    this.highlightTimer = setTimeout(() => {
      panel.classList.remove(...HIGHLIGHT)
      delete panel.dataset.highlighted
    }, HIGHLIGHT_MS)
  }

  #anchorFromHash() {
    return decodeURIComponent(location.hash.slice(1))
  }

  #show(anchor) {
    const panels = this.panelTargets
    const current = panels.find((panel) => panel.dataset.anchor === anchor) || panels[0]
    if (!current) return

    panels.forEach((panel) => { panel.hidden = panel !== current })
    this.linkTargets.forEach((link) => {
      const active = link.hash.slice(1) === current.dataset.anchor
      link.classList.remove(...(active ? this.idleClasses : this.activeClasses))
      link.classList.add(...(active ? this.activeClasses : this.idleClasses))
      const icon = link.querySelector("svg")
      icon?.classList.remove(...(active ? this.iconIdleClasses : this.iconActiveClasses))
      icon?.classList.add(...(active ? this.iconActiveClasses : this.iconIdleClasses))
      if (active) link.setAttribute("aria-current", "page")
      else link.removeAttribute("aria-current")
    })
  }
}
