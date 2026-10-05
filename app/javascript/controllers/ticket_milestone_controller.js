import ProjectScopedSelect from "controllers/project_scoped_select_controller"

// Select milestone dipendente dal progetto. La meccanica sta tutta nella base: qui si dichiara
// solo quale select governa. La mappa id milestone → id progetto arriva dal form come
// data-ticket-milestone-map-value.
export default class extends ProjectScopedSelect {
  static selectId = "milestone_id"
}
