import ProjectScopedSelect from "controllers/project_scoped_select_controller"

// Select of the slow operation a new bug is linked to: only those of the selected project. The map
// metric group id → project id arrives as data-ticket-metric-group-map-value on the form.
export default class extends ProjectScopedSelect {
  static selectId = "metric_group_id"
}
