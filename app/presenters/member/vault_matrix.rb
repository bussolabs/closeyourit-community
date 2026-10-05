# frozen_string_literal: true

module Member
  # CYRA-930 — the Vault landing: per project, its variables and files, the anomalies still open, the
  # values past their rotation date and the change requests the viewer can decide. Personal and
  # organization secrets belong to no project: they stay in the header counts. Trouble first.
  class VaultMatrix < ProjectMatrix
    COLUMNS = %i[variables files anomalies rotation requests].freeze

    def i18n_scope = "member.overviews.vault"

    def columns = COLUMNS

    def projects_scope
      open = open_anomalies.where(::Secrets::HealthAnomaly.arel_table[:project_id].eq(::Projects::Project.arel_table[:id]))
                           .select(Arel.star.count)
      @visible_projects.with_attached_icon_image.reorder(Arel.sql("(#{open.to_sql}) DESC"), :name)
    end

    def project_cells(project)
      id = project.id
      attention = ->(kind) { routes.member_vault_attention_path(project_id: [ id ], kind: [ kind ]) }
      {
        variables: count_cell(:variables, variables[id], routes.member_project_secrets_path(project)),
        files: count_cell(:files, files[id], routes.member_project_secret_assets_path(project)),
        anomalies: count_cell(:anomalies, anomalies[id], attention.call("anomaly"), alert: true, caption: anomaly_kinds(id)),
        rotation: count_cell(:rotation, rotation[id], attention.call("rotation_overdue"), alert: true),
        requests: count_cell(:requests, requests[id], attention.call("change_request"))
      }
    end

    def total_cells
      attention = ->(kind) { routes.member_vault_attention_path(kind: [ kind ]) }
      {
        variables: count_cell(:variables, variables.values.sum, routes.member_vault_projects_path),
        files: count_cell(:files, files.values.sum, routes.member_vault_projects_path(type: "files")),
        anomalies: count_cell(:anomalies, anomalies.values.sum, attention.call("anomaly"), alert: true),
        rotation: count_cell(:rotation, rotation.values.sum, attention.call("rotation_overdue"), alert: true),
        requests: count_cell(:requests, requests.values.sum, attention.call("change_request"))
      }
    end

    private

    def scoped(model) = model.where(organization_id: @organization.id, project_id: project_ids)

    def variables = @variables ||= scoped(::Secrets::Variable).group(:project_id).count

    def files = @files ||= scoped(::Secrets::Asset).active.group(:project_id).count

    # Open = neither resolved nor accepted, as on the attention page.
    def open_anomalies = scoped(::Secrets::HealthAnomaly).where(resolved_at: nil, acknowledged_at: nil)

    # One query for both: the count per project and, per project, how many of each kind.
    def anomalies_by_kind = @anomalies_by_kind ||= open_anomalies.group(:project_id, :kind).count

    def anomalies
      @anomalies ||= anomalies_by_kind.each_with_object(Hash.new(0)) { |((project_id, _), count), sums| sums[project_id] += count }
    end

    # F146 — C14: the cell says what kind of anomaly it counts, not only "still open". nil (the
    # default caption) for a project with none.
    def anomaly_kinds(project_id)
      kinds = anomalies_by_kind.select { |(id, _), _| id == project_id }
      return if kinds.empty?

      kinds.map { |(_, kind), count| I18n.t("#{i18n_scope}.anomalies.kinds.#{kind}", count:) }.join(" · ")
    end

    def rotation
      @rotation ||= ::Secrets::RotationReport.new(projects: @visible_projects).variables
                                             .select { |variable| variable.rotation_status == :overdue }
                                             .map(&:project_id).tally
    end

    def requests
      @requests ||= begin
        pending = ::Secrets::ChangeRequests::Pending.new(account: @account, projects: @visible_projects)
        pending.requests.select { |request| pending.can_decide?(request) }.map(&:project_id).tally
      end
    end
  end
end
