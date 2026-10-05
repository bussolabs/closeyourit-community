import { Controller } from "@hotwired/stimulus"

// Prefill piattaforma quando il progetto selezionato ne ha una sola. Progressive enhancement:
// senza JS il server preseleziona comunque (preselected_platform_ids). Agisce SOLO quando il
// progetto cambia davvero, così i toggle manuali sulle piattaforme non vengono sovrascritti.
export default class extends Controller {
  static values = { map: { type: Object, default: {} } }

  connect() {
    this.lastProjectId = this.projectId // baseline: non toccare la selezione iniziale (server-rendered)
  }

  // Richiamato dal change che risale dal select progetto (delegato sull'elemento form).
  refresh() {
    const projectId = this.projectId
    if (projectId === this.lastProjectId) return
    this.lastProjectId = projectId

    const select = this.element.querySelector('select[data-test="ticket-platforms"]')
    if (!select) return
    const allowed = this.mapValue[projectId] || []
    let changed = false

    Array.from(select.options).forEach((option) => {
      if (option.value === "") return
      // Toglie selezioni stale non appartenenti al nuovo progetto (validazione subset lato server).
      if (option.selected && !allowed.includes(option.value)) {
        option.selected = false
        changed = true
      }
    })

    // Progetto con UNA sola piattaforma → prefill automatico.
    if (allowed.length === 1) {
      const only = Array.from(select.options).find((option) => option.value === allowed[0])
      if (only && !only.selected) {
        only.selected = true
        changed = true
      }
    }

    // Ri-renderizza l'UI di ui--select. Ri-bolla al form ma projectId è invariato → early return.
    if (changed) select.dispatchEvent(new Event("change", { bubbles: true }))
  }

  get projectId() {
    const field = this.element.querySelector('[name="project_id"]')
    return field ? field.value : ""
  }
}
