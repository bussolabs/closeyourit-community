import ProjectScopedSelect from "controllers/project_scoped_select_controller"

// Select of the error a new bug is linked to: only the errors of the selected project. The map
// error group id → project id arrives as data-ticket-error-group-map-value on the form.
export default class extends ProjectScopedSelect {
  static selectId = "error_group_id"
}
