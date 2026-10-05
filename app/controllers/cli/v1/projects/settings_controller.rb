# frozen_string_literal: true

module Cli
  module V1
    module Projects
      # Impostazioni del progetto come sub-resource SINGLETON: retention log/analytics + flag di
      # funzionalità (roadmap/quick_bug_report/analytics). Parità col canale Member
      # (Member::ProjectSettingsController): la retention blank = eredita il default; i flag sono booleani
      # senza validazioni proprie → update_column (una colonna non correlata invalida, es. key legacy, non
      # blocca il toggle). Gate `projects.edit` (scope progetto). Anti-BOLA: il progetto si risolve in
      # visible_projects (fuori scope / altra org → R404). Applica solo i campi presenti nel request.
      class SettingsController < Cli::V1::BaseController
        FEATURE_FLAGS = %w[quick_bug_report_enabled analytics_enabled secret_approval_enabled].freeze

        before_action :set_project!
        before_action -> { require_permission!("projects.edit", scope: @project) }

        def show
          render_ok(settings_payload)
        end

        def update
          apply_feature_flags
          assign_persisted_settings
          if @project.changed? && !@project.save
            return render_error("R422-PROJECT-001", @project.errors.full_messages.to_sentence,
                                status: :unprocessable_content, details: @project.errors.to_hash)
          end

          render_ok(settings_payload)
        end

        private

        # Flag booleani senza validazioni proprie → update_column (come il toggle Member): persiste il
        # singolo campo, indipendente da colonne non correlate. Applica solo i flag presenti nel request.
        def apply_feature_flags
          FEATURE_FLAGS.each do |flag|
            next unless params.key?(flag)

            @project.update_column(flag, ActiveModel::Type::Boolean.new.cast(params[flag]))
          end
        end

        # Retention + origin allowlist: colonne con validazioni → assegnate in memoria e salvate insieme
        # (una sola save, così un valore invalido → 422). Applica solo i campi presenti nel request.
        def assign_persisted_settings
          @project.assign_attributes(retention_params) if retention_requested?
          @project.allowed_origins = params[:allowed_origins] if params.key?(:allowed_origins)
        end

        def retention_requested?
          params.key?(:logs_retention_days) || params.key?(:analytics_retention_days) ||
            params.key?(:errors_retention_days) || params.key?(:performance_retention_days) ||
            params.key?(:uptime_retention_days) || params.key?(:traces_retention_days) || params.key?(:artifacts_retention_days) || params.key?(:crashes_retention_days) || params.key?(:session_health_retention_days) || params.key?(:measurements_retention_days)
        end

        def retention_params
          params.permit(:logs_retention_days, :analytics_retention_days, :errors_retention_days,
                        :performance_retention_days, :uptime_retention_days, :traces_retention_days, :artifacts_retention_days, :crashes_retention_days, :session_health_retention_days, :measurements_retention_days)
        end

        def settings_payload
          {
            project_id: @project.id,
            logs_retention_days: @project.logs_retention_days,
            analytics_retention_days: @project.analytics_retention_days,
            errors_retention_days: @project.errors_retention_days,
            performance_retention_days: @project.performance_retention_days,
            traces_retention_days: @project.traces_retention_days,
            crashes_retention_days: @project.crashes_retention_days,
            artifacts_retention_days: @project.artifacts_retention_days,
            session_health_retention_days: @project.session_health_retention_days,
            measurements_retention_days: @project.measurements_retention_days,
            uptime_retention_days: @project.uptime_retention_days,
            allowed_origins: @project.allowed_origins,
            quick_bug_report_enabled: @project.quick_bug_report_enabled,
            analytics_enabled: @project.analytics_enabled,
            secret_approval_enabled: @project.secret_approval_enabled
          }
        end
      end
    end
  end
end
