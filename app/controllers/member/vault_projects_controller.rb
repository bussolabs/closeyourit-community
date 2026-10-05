# frozen_string_literal: true

module Member
  # Picker di progetto per lo space Vault (CYRA-133). L'area member non ha un "progetto corrente"
  # persistente, quindi al livello Progetto del Vault si sceglie qui il progetto e si atterra sulle
  # pagine secret/file ESISTENTI. Pattern Member::Monitoring::AnalyticsController: scope
  # visible.projects (anti-BOLA 404 su progetto cross-tenant), empty-state se zero progetti.
  class VaultProjectsController < Member::BaseController
    permission_not_required "Scelta del progetto della cassaforte: elenca i soli progetti visibili e rimanda alle " \
                            "pagine che gatano."

    def index
      @projects = visible.projects.order(:name).to_a
      @type = params[:type] == "files" ? "files" : "variables"

      # CYRA-404 — l'elenco dice già cosa contiene ogni progetto: quanti segreti, quante anomalie e
      # quando è stato toccato l'ultima volta. Prima era una tendina con un pulsante: si sceglieva
      # alla cieca e si aprivano i progetti uno per uno per sapere dove guardare.
      # Tre query aggregate sull'insieme visibile, non una per riga.
      project_ids = @projects.map(&:id)
      @secret_counts = ::Secrets::Variable.where(project_id: project_ids).group(:project_id).count
      @last_changes = ::Secrets::Variable.where(project_id: project_ids).group(:project_id).maximum(:updated_at)
      @anomaly_counts = ::Secrets::HealthCheck.new(projects: @projects).drifted_projects
                                              .to_h { |drifted| [ drifted.project.id, drifted.holes_count ] }

      # F162, F165 — the counts above stay on every visible project; the bar narrows the rows.
      @listed_projects = @projects
      if search_q.present?
        @listed_projects = @listed_projects.select { |project| [ project.name, project.key ].any? { |text| text.downcase.include?(search_q.downcase) } }
      end
      @listed_projects = @listed_projects.select { |project| @anomaly_counts[project.id].to_i.positive? } if params[:health] == "anomalies"

      return if params[:project_id].blank?

      project = @projects.find { |candidate| candidate.id == params[:project_id] } # anti-BOLA
      raise ActiveRecord::RecordNotFound if project.nil?

      redirect_to destination_for(project)
    end

    private

    def destination_for(project)
      @type == "files" ? member_project_secret_assets_path(project) : member_project_secrets_path(project)
    end
  end
end
