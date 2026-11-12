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
                       session_replay_enabled helpdesk_enabled supporter_enabled council_enabled
                       automator_live_code_enabled production_approval_required].freeze
    # The panels that save with their own form: a save returns to the panel it came from. It travels as
    # `?section=`, not `#anchor`: a fragment in a redirect is lost by the fetch that follows it.
    FORM_SECTIONS = %w[ingest tickets retention thresholds production delivery test supporter dashboard].freeze

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
      if @project.update(settings_params) && save_test_password
        redirect_to member_project_settings_path(@project, section: saved_section), notice: t("member.project_settings.updated")
      else
        @errors = @project.errors.to_hash.merge(@test_password_error.to_h)
        @section = saved_section
        load_settings
        render :show, status: :unprocessable_content
      end
    end

    # CYRA-1303 — the test account's password is a secret: it goes in the vault, and only who manages the
    # project's secrets may write it. A blank field leaves the stored one alone.
    def save_test_password
      password = params[:test_access_password].to_s
      return true if password.empty?

      key = if !can?("secrets.manage", scope: @project)
        "test_access_password_forbidden"
      elsif Projects::TestAccess::SavePassword.call(project: @project, password:, actor: Current.account).err?
        "test_access_password_no_staging"
      end
      return true if key.nil?

      @test_password_error = { test_access_password: [ t("member.project_settings.#{key}") ] }
      false
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
                    :performance_fast_ms, :performance_slow_ms, :production_hold_hours, :delivery_scope_check, :triage_risk_floor, :staging_deploy_proof, :production_watch, :strict_caps, :fast_lane, :light_phase_engine, :browser_proof_go_ahead, :test_access_url, :test_access_username, :test_access_not_needed,
                    :default_assignee_id, :cto_id, :owner_id, :allowed_origins, :supporter_reserved_topics)
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
