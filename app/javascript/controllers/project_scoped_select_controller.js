import { Controller } from "@hotwired/stimulus"

// Base dei select del form ticket che dipendono dal PROGETTO selezionato: mostra solo le option
// appartenenti a quel progetto (via mapValue, id option → id progetto) più la voce vuota. Se il
// progetto cambia e l'option scelta non gli appartiene, resetta a vuoto. Progressive enhancement:
// senza JS il select nativo submette comunque (il server valida che il riferimento sia del
// progetto del ticket — vedi Ticketing::CreateTicket/UpdateTicket).
//
// Il select è un Ui::SelectComponent (regola forms-select): il nativo resta nel DOM (mantiene il
// name → submette) ma è avvolto dal widget custom `ui--select`, che non espone target Stimulus
// propri sulla select nativa — lookup by-id invece di un target dichiarato. Le option non portano
// data-project-id (il componente non supporta attributi custom per-opzione): la mappa arriva come
// value JSON dal form. Dopo aver mutato hidden/disabled/value dispatchiamo "ui--select:refresh"
// perché il widget si ri-sincronizzi (vedi ui/select_controller.js).
//
// Non si usa direttamente in markup: le sottoclassi dichiarano quale select governano tramite
// `static selectId` (vedi ticket_milestone_controller.js e ticket_parent_controller.js). Servono
// due identificatori distinti perché entrambi i controller vivono sullo STESSO elemento form —
// è lì che risale il change del select progetto.
export default class extends Controller {
  static values = { map: { type: Object, default: {} } }
  static selectId = null

  connect() {
    this.refresh()
  }

  // Richiamato dal change che risale dal select progetto (delegato sull'elemento form).
  refresh() {
    const select = this.selectElement
    if (!select) return

    const projectId = this.projectId
    let selectedHidden = false

    Array.from(select.options).forEach((option) => {
      if (option.value === "") return // voce vuota: sempre visibile
      const matches = this.mapValue[option.value] === projectId && projectId !== ""
      option.hidden = !matches
      option.disabled = !matches
      if (option.selected && !matches) selectedHidden = true
    })

    if (selectedHidden) select.value = ""
    select.dispatchEvent(new CustomEvent("ui--select:refresh"))
  }

  get selectElement() {
    return this.element.querySelector(`#${this.constructor.selectId}`)
  }

  get projectId() {
    const field = this.element.querySelector('[name="project_id"]')
    return field ? field.value : ""
  }
}
