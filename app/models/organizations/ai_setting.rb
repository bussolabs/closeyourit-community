# frozen_string_literal: true

module Organizations
  # How one organization uses the AI (CYRA-914 phase 2). No row, or mode "platform", means the
  # platform values; "variation" changes models and the token cap on the platform provider; "own"
  # brings a whole OpenAI-compatible provider. Ai::Configuration applies the precedence.
  class AiSetting < ApplicationRecord
    self.table_name = "organization_ai_settings"

    MODES = %w[platform variation own].freeze
    SECRET_COLUMNS = %w[api_key rerank_api_key].freeze
    URL_FORMAT = %r{\Ahttps?://\S+\z}i

    belongs_to :organization, class_name: "Organizations::Organization", inverse_of: :ai_setting

    encrypts :api_key
    encrypts :rerank_api_key

    validates :organization_id, uniqueness: true
    validates :mode, inclusion: { in: MODES }
    validates :base_url, :api_key, :chat_model, presence: true, if: :own?
    validates :base_url, :api_key, absence: true, unless: :own?
    validates :base_url, :rerank_base_url, format: { with: URL_FORMAT }, allow_blank: true
    validates :monthly_token_cap, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
    validate :addresses_outside_internal_network
    validate :keys_reentered_for_new_addresses

    # Literal internal IPs and local names are refused here; a name that resolves inside is refused
    # at call time, where Ai::ProviderHttp pins the public address (CYRA-914).
    INTERNAL_SUFFIXES = %w[.localhost .local .internal].freeze
    # A saved key only ever travels to the address it was saved with.
    KEY_FOR_ADDRESS = { base_url: :api_key, rerank_base_url: :rerank_api_key }.freeze

    after_commit { Ai::Configuration.reset! }

    def own? = mode == "own"
    def variation? = mode == "variation"

    # Keys kept from the database while their address changed: they must be typed again, or they would
    # leave for an address the person who saved them never chose (CYRA-914).
    def stale_keys
      KEY_FOR_ADDRESS.filter_map do |address, key|
        key if attribute_in_database(address).present? && will_save_change_to_attribute?(address) &&
               !will_save_change_to_attribute?(key) && public_send(key).present?
      end
    end

    def serializable_hash(options = nil)
      options = (options || {}).dup
      options[:except] = Array(options[:except]).map(&:to_s) | SECRET_COLUMNS
      super
    end

    private

    def addresses_outside_internal_network
      %i[base_url rerank_base_url].each do |attribute|
        host = URI.parse(public_send(attribute).to_s).hostname.to_s.downcase
        errors.add(attribute, :internal_address) if host.present? && internal_host?(host)
      rescue URI::InvalidURIError
        nil
      end
    end

    def keys_reentered_for_new_addresses
      stale_keys.each { |key| errors.add(key, :reenter_for_new_address) }
    end

    def internal_host?(host)
      return NetworkGuard.blocked_address?(host) if NetworkGuard.ip_literal?(host)

      host == "localhost" || host.end_with?(*INTERNAL_SUFFIXES)
    end
  end
end
