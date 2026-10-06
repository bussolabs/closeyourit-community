# frozen_string_literal: true

module Member
  # Impostazioni del progetto (tab Settings): override della retention log. Scoping anti-BOLA all'org,
  # gate projects.edit. Controller flat (non Member::Projects::*) per non ombreggiare il namespace
  # ::Projects (model), come ProjectTokensController.
  class ProjectSettingsController < Member::BaseController
    include Member::ProjectSettingsPage

    # CYRA-376 — session_replay_enabled esisteva sul progetto e gatava l'ingest, ma nessuna
    # schermata lo accendeva: la funzione si poteva solo scoprire, mai attivare.
    FEATURE_FLAGS = %w[quick_bug_report_enabled analytics_enabled secret_approval_enabled
                       session_replay_enabled helpdesk_enabled supporter_enabled].freeze
    # The panels that save with their own form: a save returns to the panel it came from. It travels as
    # `?section=`, not `#anchor`: a fragment in a redirect is lost by the fetch that follows it.
    FORM_SECTIONS = %w[ingest tickets retention thresholds supporter].freeze

    before_action :set_project
    # CYRA-883 — the page also holds the ingest tokens: whoever manages them (the default Maintainer,
    # who cannot edit the project) opens it and sees that section only. Saving still needs projects.edit.
    before_action :require_settings_access, only: :show
    before_action :require_edit, only: :update

    def show
      @section = saved_section
      load_settings
    end

    def update
      respond_to do |format|
        format.html { update_retention }
        format.json { toggle_feature } # switch via fetch (auto-save, no reload)
      end
    end

    private

    # Form impostazioni (HTML): retention (1..365 / blank = eredita) + assegnatario di default dei ticket.
    def update_retention
      if @project.update(settings_params)
        redirect_to member_project_settings_path(@project, section: saved_section), notice: t("member.project_settings.updated")
      else
        @errors = @project.errors.to_hash
        @section = saved_section
        load_settings
        render :show, status: :unprocessable_content
      end
    end

    # Switch funzionalità (JSON): persiste il singolo flag booleano con update_column, così un
    # record con un campo non correlato invalido (es. legacy con key troppo lunga) non blocca il
    # toggle — i flag non hanno validazioni proprie. 204 senza body, niente reload lato client.
    def toggle_feature
      flag, value = feature_toggle
      return head(:unprocessable_content) unless flag

      @project.update_column(flag, value)
      head :no_content
    end

    def saved_section
      params[:section].presence_in(FORM_SECTIONS)
    end

    def feature_toggle
      permitted = params.permit(*FEATURE_FLAGS)
      flag = FEATURE_FLAGS.find { |f| permitted.key?(f) }
      return [ nil, nil ] unless flag

      [ flag.to_sym, ActiveModel::Type::Boolean.new.cast(permitted[flag]) ]
    end

    # Anti-BOLA + scoping: progetto non visibile (altra org o non assegnato) → RecordNotFound.
    def set_project
      @project = visible.projects.find(params[:project_id])
    end

    def settings_params
      # allowed_origins arriva come stringa multi-riga dalla textarea; il model la normalizza (CYRA-109).
      # CYRA-341: performance_fast_ms/performance_slow_ms = soglie di colore delle durate (Metrics::Thresholds).
      params.permit(:logs_retention_days, :analytics_retention_days, :errors_retention_days,
                    :performance_retention_days, :uptime_retention_days, :traces_retention_days, :artifacts_retention_days, :crashes_retention_days, :session_health_retention_days, :measurements_retention_days,
                    :performance_fast_ms, :performance_slow_ms,
                    :default_assignee_id, :cto_id, :allowed_origins, :supporter_reserved_topics)
    end

    def require_edit
      require_permission!("projects.edit", scope: @project)
    end

    def require_settings_access
      return if can?("projects.edit", scope: @project)

      require_permission!("tokens.manage", scope: @project)
    end
  end
end
