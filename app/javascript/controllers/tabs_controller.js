import { Controller } from "@hotwired/stimulus"

// Schede semplici: mostra un pannello per volta, in coppia con i bottoni `tab`. Progressive enhancement
// — nel markup nessun pannello è nascosto, quindi senza JS restano tutti leggibili; con JS si mostra
// solo l'attivo. Usato dalla sezione «Usa questo segreto» del Vault (CYRA-401).
export default class extends Controller {
  static targets = ["tab", "panel"]

  connect() {
    this.show(0)
  }

  select(event) {
    this.show(event.params.index)
  }

  show(index) {
    this.panelTargets.forEach((panel, i) => { panel.hidden = i !== index })
    this.tabTargets.forEach((tab, i) => { tab.setAttribute("aria-selected", i === index ? "true" : "false") })
  }
}
