# frozen_string_literal: true

module Seo
  # Il `robots.txt` del sito, letto per obbedirgli. Non è un'opzione e non ha un interruttore: un
  # crawler che ignora robots.txt è un crawler che verrà bloccato, e avrebbe ragione chi lo blocca.
  #
  # Implementa la parte dello standard che serve davvero: gruppi `User-agent`, `Disallow`, `Allow`
  # con la regola del match più lungo (quella che usano i motori veri), e le righe `Sitemap:`.
  # Fuori restano `Crawl-delay` — abbiamo già una pausa fissa, più prudente di quasi ogni valore
  # dichiarato — e i pattern con `$`/`*`, che si vedono raramente e la cui approssimazione
  # sbagliata farebbe più danni del non averli.
  class Robots
    Rule = Data.define(:path, :allow)

    attr_reader :sitemaps

    # Nessun robots.txt (404, guasto, host muto) = tutto permesso: è lo stesso comportamento dei
    # motori di ricerca. Un file irraggiungibile è un rilievo (`robots_unreachable`), non un divieto.
    def self.permissive = new(rules: [], sitemaps: [])

    def self.parse(text, user_agent: Seo::Fetch::USER_AGENT)
      return permissive if text.blank?

      token = user_agent.to_s.split("/").first.to_s.downcase
      groups = Hash.new { |hash, key| hash[key] = [] }
      sitemaps = []
      current_agents = []
      agents_closed = false

      text.each_line do |line|
        line = line.split("#").first.to_s.strip
        next if line.blank?

        field, value = line.split(":", 2)
        field = field.to_s.strip.downcase
        value = value.to_s.strip
        next if value.blank? && field != "disallow"

        case field
        when "user-agent"
          # Un nuovo blocco di user-agent inizia solo dopo almeno una regola: `User-agent: a` e
          # `User-agent: b` di fila condividono le regole che seguono.
          current_agents = [] if agents_closed
          current_agents << value.downcase
          agents_closed = false
        when "disallow", "allow"
          agents_closed = true
          current_agents.each { |agent| groups[agent] << Rule.new(path: value, allow: field == "allow") }
        when "sitemap"
          sitemaps << value
        end
      end

      # Il gruppo specifico per noi vince su quello generico, come vuole lo standard.
      rules = groups[token].presence || groups["*"] || []
      new(rules:, sitemaps:)
    end

    def initialize(rules:, sitemaps:)
      @rules = rules
      @sitemaps = sitemaps
    end

    # Match più lungo, e a parità vince `Allow`: è la regola dei motori, e sbagliarla significa
    # escludere pagine che il proprietario voleva farci vedere.
    def allowed?(path)
      candidate = @rules.select { |rule| rule.path.present? && path.to_s.start_with?(rule.path) }
                        .max_by { |rule| [ rule.path.length, rule.allow ? 1 : 0 ] }
      return true if candidate.nil?

      candidate.allow
    end

    # `Disallow:` senza valore significa "niente è vietato": è il modo standard di dire "prego".
    def blocks_everything? = @rules.any? { |rule| !rule.allow && rule.path == "/" }
  end
end
