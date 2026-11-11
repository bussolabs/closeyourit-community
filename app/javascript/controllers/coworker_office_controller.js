import { Controller } from "@hotwired/stimulus"

// Coworkers office (CYRA-1283): loads the 3D scene only on this page and shows the card of the Puck
// picked in the scene.
export default class extends Controller {
  static targets = ["stage", "fallback", "hint", "panel", "follow", "discoveryStatus"]
  static values = { puckies: Array, places: Object, rooms: Array, discoveries: Object }

  async connect() {
    try {
      const { createOffice } = await import("coworker_office/scene")
      const office = await createOffice({ stage: this.stageTarget, puckies: this.puckiesValue, places: this.placesValue, rooms: this.roomsValue, onSelect: (id) => this.#select(id), onDiscover: (id) => this.#discovered(id), onFollowChange: (active) => this.followTarget.setAttribute("aria-pressed", String(active)) })
      // The page may have been left while the scene was loading.
      if (this.element.isConnected) this.office = office
      else office.dispose()
    } catch (error) {
      console.error(error)
      this.fallbackTarget.hidden = false
    }
  }

  disconnect() {
    this.office?.dispose()
    this.office = null
  }

  reset() {
    this.office?.reset()
  }

  follow() { this.office?.follow() }

  view(event) { this.office?.view(event.currentTarget.dataset.view) }

  atmosphere(event) {
    this.office?.atmosphere(event.currentTarget.value)
  }

  discover(event) { this.office?.discover(event.currentTarget.dataset.discovery) }

  #discovered(id) {
    this.discoveryStatusTarget.hidden = false
    this.discoveryStatusTarget.textContent = this.discoveriesValue[id] || ""
  }

  choose(event) {
    this.#select(event.currentTarget.dataset.puckId)
  }

  #select(id) {
    const key = String(id)
    this.followTarget.disabled = false
    this.hintTarget.hidden = true
    this.panelTargets.forEach((panel) => { panel.hidden = panel.dataset.puckId !== key })
    this.office?.select(id)
  }
}
