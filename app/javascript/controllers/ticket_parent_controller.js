import ProjectScopedSelect from "controllers/project_scoped_select_controller"

// Select dell'epic padre, dipendente dal progetto (CYRA-223): un ticket può stare solo sotto un
// epic del PROPRIO progetto. La mappa id epic → id progetto arriva come
// data-ticket-parent-map-value dal form.
export default class extends ProjectScopedSelect {
  static selectId = "parent_id"
}
