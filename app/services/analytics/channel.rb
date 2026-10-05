# frozen_string_literal: true

module Analytics
  # Classifica una sorgente (referrer_host + utm_medium/source) in un canale stile GA/Plausible.
  # Regole in ordine di priorità: paid → email → social → AI → search → referral → direct.
  class Channel
    SEARCH = %w[google bing duckduckgo yahoo ecosia yandex baidu brave qwant].freeze
    SOCIAL = %w[facebook fb instagram twitter x.com t.co linkedin reddit youtube tiktok pinterest threads mastodon].freeze
    AI = %w[chatgpt openai claude perplexity gemini copilot bard].freeze
    PAID_MEDIUMS = %w[cpc ppc paid paidsearch paid_search cpm display banner].freeze
    SOCIAL_MEDIUMS = %w[social social-network social_network sm].freeze

    DIRECT = "Direct"

    def self.classify(referrer_host:, utm_medium:, utm_source:)
      medium = utm_medium.to_s.downcase
      host = referrer_host.to_s.downcase
      source = utm_source.to_s.downcase

      return "Paid" if PAID_MEDIUMS.include?(medium)
      return "Email" if medium == "email" || source == "newsletter"
      return "Organic Social" if SOCIAL_MEDIUMS.include?(medium) || host_matches?(host, SOCIAL)
      return "AI Assistants" if host_matches?(host, AI)
      return "Organic Search" if host_matches?(host, SEARCH)
      return "Referral" if host.present?

      DIRECT
    end

    # Un token con punto è un dominio (match esatto o sottodominio: "x.com"/"a.x.com"); un token
    # senza punto è una parola, matchata contro i label del dominio (evita che "t.co" agganci
    # "chatgpt.com" per substring).
    def self.host_matches?(host, tokens)
      return false if host.blank?

      labels = host.split(".")
      tokens.any? do |t|
        t.include?(".") ? (host == t || host.end_with?(".#{t}")) : labels.include?(t)
      end
    end
    private_class_method :host_matches?
  end
end
