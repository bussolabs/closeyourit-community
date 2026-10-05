# frozen_string_literal: true

module Valhalla
  # Where the AI features send their requests (CYRA-916): the environment, a CloseYourIt AI key or
  # any OpenAI-compatible provider. Saved encrypted in Settings::Global, read by Ai::Configuration.
  # A new search model clears every stored vector, so that change waits for an explicit yes.
  class AiSettingsController < BaseController
    KEY_FIELDS = %i[ai_api_key ai_rerank_api_key].freeze
    # Keys typed before the reindex confirmation ride along encrypted, never in clear (CYRA-914 P9).
    PENDING_KEYS_TTL = 10.minutes

    def self.pending_keys_encryptor
      ActiveSupport::MessageEncryptor.new(Rails.application.key_generator.generate_key("valhalla ai pending keys", 32))
    end

    before_action :load_settings

    def show; end

    def update
      @settings.assign_attributes(ai_params)
      return ask_reindex_confirmation if reindex_needed? && params[:confirm_reindex].blank?

      reindex = reindex_needed?
      if @settings.save
        Embeddings::ResizeColumnsJob.perform_later(dimensions: new_config.embedding_dimensions) if reindex
        redirect_to valhalla_ai_settings_path, notice: t("valhalla.ai_settings.updated")
      else
        @errors = @settings.errors.to_hash
        render :show, status: :unprocessable_content
      end
    end

    def test
      @settings.assign_attributes(ai_params)
      @checks = Ai::TestConnection.call(config: new_config).value
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.update("ai-checks", partial: "valhalla/ai_settings/checks",
                                                                locals: { checks: @checks })
        end
        format.html { render :show }
      end
    end

    private

    def load_settings
      @settings = Settings::Global.instance
    end

    def ask_reindex_confirmation
      @confirm_reindex = true
      @pending_keys = pending_keys_token
      render :show, status: :unprocessable_content
    end

    def new_config = Ai::Configuration.build(@settings)

    def reindex_needed?
      new_config.embeddings_configured? &&
        new_config.embedding_version != Ai::Configuration.current.embedding_version
    end

    # An empty key field keeps the stored key, unless one was typed before the reindex confirmation:
    # the page never shows a key back.
    def ai_params
      permitted = params.permit(*Settings::Global::AI_PROVIDER_COLUMNS, :ai_org_monthly_token_cap).to_h.symbolize_keys
      permitted[:ai_provider] = nil if permitted[:ai_provider].blank? || permitted[:ai_provider] == "environment"
      permitted[:ai_org_monthly_token_cap] = permitted[:ai_org_monthly_token_cap].presence if permitted.key?(:ai_org_monthly_token_cap)
      pending = pending_keys
      KEY_FIELDS.each do |field|
        next if permitted[field].present?

        pending[field].present? ? permitted[field] = pending[field] : permitted.delete(field)
      end
      permitted
    end

    def pending_keys_token
      keys = KEY_FIELDS.select { |field| @settings.public_send(:"#{field}_changed?") }
                       .index_with { |field| @settings.public_send(field) }.compact_blank
      return if keys.empty?

      self.class.pending_keys_encryptor.encrypt_and_sign(keys, expires_in: PENDING_KEYS_TTL, purpose: :ai_pending_keys)
    end

    def pending_keys
      token = params[:pending_keys].presence
      return {} unless token.is_a?(String)

      (self.class.pending_keys_encryptor.decrypt_and_verify(token, purpose: :ai_pending_keys) || {}).symbolize_keys
    rescue ActiveSupport::MessageEncryptor::InvalidMessage
      {}
    end
  end
end
