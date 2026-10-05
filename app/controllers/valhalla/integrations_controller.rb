# frozen_string_literal: true

module Valhalla
  # GitHub App and Telegram values of the platform (CYRA-914): saved encrypted in Settings::Global and
  # read through Settings::Integrations, with the environment as fallback. Secrets are never shown
  # back; a webhook secret generated here is shown once, to paste into GitHub or BotFather.
  class IntegrationsController < BaseController
    GENERATED = %i[gh_webhook_secret telegram_webhook_secret].freeze

    before_action :load_settings

    def show; end

    def update
      if @settings.update(integration_params)
        redirect_to valhalla_integrations_path, notice: t("valhalla.integrations.updated")
      else
        @errors = @settings.errors.to_hash
        render :show, status: :unprocessable_content
      end
    end

    def generate
      field = GENERATED.find { |name| name.to_s == params[:field] }
      # The current secret stops working at once: only a confirmed gesture replaces it.
      return head(:unprocessable_content) if field.nil? || params[:confirm].blank?

      @generated = { field:, value: SecureRandom.hex(32) }
      @settings.update!(field => @generated[:value])
      # Turbo drops a 200 page answering a form, so the secret would never be seen: replace the page instead.
      respond_to do |format|
        format.turbo_stream { render turbo_stream: turbo_stream.replace("valhalla-integrations", partial: "valhalla/integrations/page") }
        format.html { render :show }
      end
    end

    private

    def load_settings
      @settings = Settings::Global.instance
    end

    # An empty secret field keeps the stored secret: the page never shows one back.
    def integration_params
      permitted = params.permit(*Settings::Integrations::FIELDS.keys).to_h.symbolize_keys
      Settings::Integrations::SECRET_FIELDS.each { |field| permitted.delete(field) if permitted[field].blank? }
      permitted.transform_values(&:presence)
    end
  end
end
