import { Controller } from "@hotwired/stimulus"

// Schede semplici: mostra un pannello per volta, in coppia con i bottoni `tab`. Progressive enhancement
// — nel markup nessun pannello è nascosto, quindi senza JS restano tutti leggibili; con JS si mostra
// solo l'attivo. Usato dalla sezione «Usa questo segreto» del Vault (CYRA-401).
// CYRA-1003 — `index` opens a tab other than the first; a URL anchor inside a panel opens that panel.
export default class extends Controller {
  static targets = ["tab", "panel"]
  static values = { index: { type: Number, default: 0 } }

  connect() {
    const anchored = this.#anchoredPanel()
    this.show(anchored >= 0 ? anchored : this.indexValue)
  }

  select(event) {
    this.show(event.params.index)
  }

  show(index) {
    this.panelTargets.forEach((panel, i) => { panel.hidden = i !== index })
    this.tabTargets.forEach((tab, i) => { tab.setAttribute("aria-selected", i === index ? "true" : "false") })
  }

  #anchoredPanel() {
    const id = decodeURIComponent(window.location.hash.slice(1))
    if (!id) return -1

    return this.panelTargets.findIndex((panel) => panel.id === id || panel.querySelector(`[id="${CSS.escape(id)}"]`))
  }
}
