# frozen_string_literal: true

module Valhalla
  # Configurazione globale di sistema (god-only via Valhalla::BaseController): retention di default
  # di log e analytics (livello più alto della gerarchia god → org → progetto) e interruttori delle
  # funzioni AI (Ai::Feature).
  #
  # Due canali sullo STESSO update: il form della retention (HTML → redirect) e gli switch AI, che
  # sono auto-save e arrivano in JSON dallo Stimulus `ui--switch` — come i toggle della tab GitHub.
  class SettingsController < BaseController
    def show
      @settings = Settings::Global.instance
    end

    def update
      @settings = Settings::Global.instance
      updated = @settings.update(settings_params)

      respond_to do |format|
        format.json { render_switch_result(updated) }
        format.html { render_form_result(updated) }
      end
    end

    private

    def render_switch_result(updated)
      return head :ok if updated

      render json: { error: { message: @settings.errors.full_messages.to_sentence } },
             status: :unprocessable_content
    end

    def render_form_result(updated)
      if updated
        redirect_to valhalla_settings_path, notice: t("valhalla.settings.updated")
      else
        @errors = @settings.errors.to_hash
        render :show, status: :unprocessable_content
      end
    end

    # Gli interruttori AI sono elencati dal model (AI_SWITCH_COLUMNS), fonte unica: aggiungere un
    # servizio a Ai::Feature::KEYS lo rende salvabile senza toccare il controller.
    def settings_params
      params.permit(:logs_retention_days, :analytics_retention_days, :errors_retention_days,
                    :performance_retention_days, :servers_retention_days, :uptime_retention_days, :traces_retention_days, :artifacts_retention_days, :crashes_retention_days, :session_health_retention_days, :measurements_retention_days,
                    *Settings::Global::AI_SWITCH_COLUMNS)
    end
  end
end
