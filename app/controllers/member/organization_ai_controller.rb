# frozen_string_literal: true

module Member
  # How the current organization uses the AI (CYRA-914): the platform values, a variation of the
  # models and token cap, or its own OpenAI-compatible provider. Gate ai.manage; the organization is
  # always Current.organization, never an id from the request. Keys are never shown back.
  class OrganizationAiController < Member::BaseController
    FIELDS = %i[mode base_url api_key chat_model embedding_model transcription_model
                rerank_base_url rerank_api_key rerank_model monthly_token_cap].freeze
    KEY_FIELDS = %i[api_key rerank_api_key].freeze
    # Keys typed before the reindex confirmation ride along encrypted, never in clear (as Valhalla, P9).
    PENDING_KEYS_TTL = 10.minutes

    def self.pending_keys_encryptor
      ActiveSupport::MessageEncryptor.new(Rails.application.key_generator.generate_key("organization ai pending keys", 32))
    end

    # Saving is a dangerous gesture (a whole provider, keys): it asks for confirmation. A test saves nothing.
    before_action -> { require_permission!("ai.manage") }, except: :test
    before_action -> { redirect_to(root_path, alert: t("member.forbidden")) unless can?("ai.manage") }, only: :test
    before_action :load_setting

    def show; end

    def update
      @setting.assign_attributes(setting_params)
      reindex = reindex_needed?
      return ask_reindex_confirmation if reindex && params[:confirm_reindex].blank?

      if @setting.save
        Embeddings::ReembedOrganizationJob.perform_later(organization_id: Current.organization.id) if reindex
        redirect_to member_organization_ai_path, notice: t("member.organization_ai.updated")
      else
        @errors = @setting.errors.to_hash
        render :show, status: :unprocessable_content
      end
    end

    def test
      @setting.assign_attributes(setting_params)
      @setting.stale_keys.each { |key| @setting.public_send(:"#{key}=", nil) }
      @checks = ::Ai::TestConnection.call(config: ::Ai::Configuration.preview(@setting)).value
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.update("ai-checks", partial: "valhalla/ai_settings/checks",
                                                                locals: { checks: @checks })
        end
        format.html { render :show }
      end
    end

    private

    def ask_reindex_confirmation
      @confirm_reindex = true
      @pending_keys = pending_keys_token
      render :show, status: :unprocessable_content
    end

    # A new search model makes this organization's vectors stale; the other organizations keep theirs.
    def reindex_needed?
      config = ::Ai::Configuration.preview(@setting)
      config.embeddings_configured? &&
        config.embedding_version != ::Ai::Configuration.for(Current.organization).embedding_version
    end

    def pending_keys_token
      keys = KEY_FIELDS.select { |field| @setting.public_send(:"#{field}_changed?") }
                       .index_with { |field| @setting.public_send(field) }.compact_blank
      return if keys.empty?

      self.class.pending_keys_encryptor.encrypt_and_sign(keys, expires_in: PENDING_KEYS_TTL, purpose: :org_ai_pending_keys)
    end

    def pending_keys
      token = params[:pending_keys].presence
      return {} unless token.is_a?(String)

      (self.class.pending_keys_encryptor.decrypt_and_verify(token, purpose: :org_ai_pending_keys) || {}).symbolize_keys
    rescue ActiveSupport::MessageEncryptor::InvalidMessage
      {}
    end

    def load_setting
      @setting = Organizations::AiSetting.find_or_initialize_by(organization: Current.organization)
    end

    # An empty key field keeps the stored key; fields a mode does not use are cleared, so a variation
    # never keeps an address or a key left over from an own provider.
    def setting_params
      permitted = params.permit(*FIELDS).to_h.symbolize_keys
      pending = pending_keys
      KEY_FIELDS.each do |field|
        next if permitted[field].present?

        pending[field].present? ? permitted[field] = pending[field] : permitted.delete(field)
      end
      permitted.transform_values { |value| value.presence }.tap do |values|
        values[:mode] ||= "platform"
        values.merge!(base_url: nil, api_key: nil, rerank_base_url: nil, rerank_api_key: nil) unless values[:mode] == "own"
      end
    end
  end
end
