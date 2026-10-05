# frozen_string_literal: true

module Ai
  # Where the AI features send their requests and with which models (CYRA-916).
  #
  # Platform sources, chosen in Valhalla (Settings::Global#ai_provider):
  #   * nil          — the environment, as before: AI_BASE_URL, EMBED_BASE_URL, CHAT_BASE_URL, AI_API_KEY.
  #   * "closeyourit" — a CloseYourIt AI key; addresses and models are ours.
  #   * "custom"      — any OpenAI-compatible provider, with the models the admin picked.
  # On top, Organizations::AiSetting of Current.organization (CYRA-914): organization -> Valhalla ->
  # environment, with the source of each field in #sources. The embedding size is always the platform's.
  # The settings rows are memoized for the request or job in Current: the embedding version is read inside loops.
  class Configuration
    PROVIDERS = %w[closeyourit custom].freeze
    CLOSEYOURIT_BASE_URL = "https://api.closeyour.it/v1"
    # pgvector cannot build an HNSW index on a `vector` column wider than this.
    MAX_EMBEDDING_DIMENSIONS = 2000

    Snapshot = Data.define(:provider, :api_key, :chat_base_url, :review_base_url, :embed_base_url,
                           :chat_model, :embedding_model, :embedding_dimensions, :embedding_version,
                           :transcription_model, :rerank_base_url, :rerank_api_key, :rerank_model,
                           :monthly_token_cap, :sources) do
      def chat_configured? = api_key.present? && chat_base_url.present? && chat_model.present?
      def review_configured? = api_key.present? && review_base_url.present? && chat_model.present?
      def transcription_configured? = chat_configured? && transcription_model.present?
      def embeddings_configured? = api_key.present? && embed_base_url.present? && embedding_model.present?
      def rerank_configured? = rerank_base_url.present? && rerank_api_key.present? && rerank_model.present?

      # The keys stay readable by name but never leave through inspect or JSON (CYRA-914 D13).
      SECRET_FIELDS = %i[api_key rerank_api_key].freeze

      def inspect = "#<Ai::Configuration::Snapshot #{to_h.except(*SECRET_FIELDS)}>"
      alias_method :to_s, :inspect
      def pretty_print(printer) = printer.text(inspect)

      URL_FIELDS = %i[chat_base_url review_base_url embed_base_url rerank_base_url].freeze

      # An address typed by an organization: calls to it go through Ai::ProviderHttp's guard.
      def untrusted_url?(url)
        wanted = url.to_s.chomp("/")
        URL_FIELDS.any? { |field| sources[field] == :organization && public_send(field).to_s.chomp("/") == wanted }
      end

      def as_json(*) = to_h.except(*SECRET_FIELDS).as_json
    end

    FIELDS = (Snapshot.members - [ :sources ]).freeze
    # What a "variation" may change on the platform provider: models only, never address or key.
    VARIATION_FIELDS = %i[chat_model embedding_model transcription_model rerank_model].freeze

    class << self
      def current = self.for(Current.organization)

      def for(organization) = for_id(organization&.id)

      # By id, so loops over records (backfills, drift counts) need no organization row. Only the rows
      # read from the database are memoized; the snapshot is rebuilt, as before, from them and ENV.
      def for_id(organization_id) = with_organization(platform, organization_id)

      # Every embedding version in use: the platform's and those of organizations with their own model.
      def embedding_versions
        (organization_settings.keys.map { |id| for_id(id).embedding_version } << for_id(nil).embedding_version).uniq
      end

      # The configuration an organization would get with these settings, saved or not (page preview, test).
      def preview(setting) = apply(platform, setting)

      def reset! = Current.ai_configuration = nil

      def build(settings)
        snapshot = case settings&.ai_provider
        when "closeyourit" then closeyourit(settings)
        when "custom" then custom(settings)
        else environment
        end
        cap = settings&.ai_org_monthly_token_cap
        return snapshot if cap.nil?

        snapshot.with(monthly_token_cap: cap, sources: snapshot.sources.merge(monthly_token_cap: :valhalla))
      end

      private

      def platform
        memo = (Current.ai_configuration ||= {})
        memo[:settings] = read_settings unless memo.key?(:settings)
        build(memo[:settings])
      end

      def with_organization(base, organization_id)
        apply(base, organization_id && organization_settings[organization_id])
      end

      def apply(base, setting)
        if setting&.own? then own(base, setting)
        elsif setting&.variation? then variation(base, setting)
        else base
        end
      end

      # One query per request or job: only organizations that changed something have a row that counts.
      def organization_settings
        (Current.ai_configuration ||= {})[:organizations] ||=
          Organizations::AiSetting.where(mode: %w[variation own]).index_by(&:organization_id)
      rescue ActiveRecord::StatementInvalid => e
        Rails.logger.warn("[ai-configuration] organization settings unreadable, using the platform: #{e.class}")
        {}
      end

      def variation(base, setting)
        changes = VARIATION_FIELDS.to_h { |field| [ field, setting.public_send(field).presence ] }.compact
        cap = setting.monthly_token_cap
        changes[:monthly_token_cap] = cap if cap && (base.monthly_token_cap.nil? || cap < base.monthly_token_cap)
        return base if changes.empty?

        if changes.key?(:embedding_model) && changes[:embedding_model] != base.embedding_model
          changes[:embedding_version] = organization_version(setting, changes[:embedding_model], base)
        end
        base.with(**changes, sources: base.sources.merge(changes.keys.to_h { |field| [ field, :organization ] }))
      end

      def own(base, setting)
        url = setting.base_url.presence&.chomp("/")
        model = setting.embedding_model.presence
        values = { provider: "organization", api_key: setting.api_key, chat_base_url: url, review_base_url: url,
                   embed_base_url: url, chat_model: setting.chat_model.presence, embedding_model: model,
                   embedding_dimensions: base.embedding_dimensions,
                   embedding_version: organization_version(setting, model, base),
                   transcription_model: setting.transcription_model.presence,
                   rerank_base_url: setting.rerank_base_url.presence&.chomp("/"),
                   rerank_api_key: setting.rerank_api_key.presence, rerank_model: setting.rerank_model.presence,
                   monthly_token_cap: setting.monthly_token_cap }
        sources = FIELDS.to_h { |field| [ field, :organization ] }
        Snapshot.new(**values, sources: sources.merge(embedding_dimensions: base.sources[:embedding_dimensions]))
      end

      # Vectors of another model live beside the platform's ones: the version keeps searches apart.
      def organization_version(setting, model, base)
        "org:#{setting.organization_id}:#{model}:#{base.embedding_dimensions}"
      end

      def sourced(source, **values)
        Snapshot.new(monthly_token_cap: nil, **values, sources: FIELDS.to_h { |field| [ field, source ] })
      end

      def read_settings
        Settings::Global.first
      rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError => e
        # Same fail-open as Ai::Feature: an unreadable settings row must not switch the AI off.
        Rails.logger.warn("[ai-configuration] settings unreadable, using the environment: #{e.class}")
        nil
      end

      def environment
        api_key = ENV["AI_API_KEY"]
        sourced(:environment, provider: nil, api_key:, chat_base_url: ENV["AI_BASE_URL"],
                     review_base_url: ENV["CHAT_BASE_URL"], embed_base_url: ENV["EMBED_BASE_URL"],
                     chat_model: Ai::Llm::Constants::MODEL, embedding_model: Ai::Constants::EMBEDDING_MODEL,
                     embedding_dimensions: Ai::Constants::EMBEDDING_DIMENSIONS,
                     embedding_version: Ai::Constants::EMBEDDING_VERSION,
                     transcription_model: Ai::Llm::Constants::TRANSCRIPTION_MODEL,
                     rerank_base_url: ENV["EMBED_BASE_URL"], rerank_api_key: api_key,
                     rerank_model: Ai::Constants.rerank_model)
      end

      def closeyourit(settings)
        api_key = settings.ai_api_key
        url = CLOSEYOURIT_BASE_URL
        sourced(:valhalla, provider: "closeyourit", api_key:, chat_base_url: url, review_base_url: url,
                     embed_base_url: url, chat_model: Ai::Llm::Constants::MODEL,
                     embedding_model: Ai::Constants::EMBEDDING_MODEL,
                     embedding_dimensions: Ai::Constants::EMBEDDING_DIMENSIONS,
                     embedding_version: Ai::Constants::EMBEDDING_VERSION,
                     transcription_model: Ai::Llm::Constants::TRANSCRIPTION_MODEL,
                     rerank_base_url: url, rerank_api_key: api_key, rerank_model: Ai::Constants::RERANK_MODEL)
      end

      def custom(settings)
        url = settings.ai_base_url.presence&.chomp("/")
        dimensions = settings.ai_embedding_dimensions
        sourced(:valhalla, provider: "custom", api_key: settings.ai_api_key, chat_base_url: url, review_base_url: url,
                     embed_base_url: url, chat_model: settings.ai_chat_model.presence,
                     embedding_model: settings.ai_embedding_model.presence,
                     embedding_dimensions: dimensions,
                     embedding_version: "custom:#{settings.ai_embedding_model}:#{dimensions}",
                     transcription_model: settings.ai_transcription_model.presence,
                     rerank_base_url: settings.ai_rerank_base_url.presence&.chomp("/"),
                     rerank_api_key: settings.ai_rerank_api_key.presence,
                     rerank_model: settings.ai_rerank_model.presence)
      end
    end
  end
end
