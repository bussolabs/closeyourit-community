import { Controller } from "@hotwired/stimulus"

// One panel at a time, picked from a side menu of `#anchor` links. The address keeps the open panel, so a
// reload or a shared link opens the same one; without a fragment, `initial` is the panel the server wants
// open (the one just saved, or a save that failed). Without JS nothing is hidden and the links scroll to
// their panel as plain anchors.
export default class extends Controller {
  static targets = ["panel", "link"]
  static values = { initial: String }
  static classes = ["active", "idle", "iconActive", "iconIdle"]

  connect() {
    this.onHashChange = () => this.#show(this.#anchorFromHash())
    window.addEventListener("hashchange", this.onHashChange)
    this.#show(this.#anchorFromHash() || this.initialValue)
  }

  disconnect() {
    window.removeEventListener("hashchange", this.onHashChange)
  }

  open(event) {
    event.preventDefault()
    const anchor = event.currentTarget.hash.slice(1)
    history.replaceState(history.state, "", `${location.pathname}#${anchor}`)
    this.#show(anchor)
    this.element.closest("main")?.scrollTo({ top: 0 })
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
