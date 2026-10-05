# frozen_string_literal: true

module Agents
  # Lettura unica dei piani storici v1 e dei decision packet v2. La struttura resta il dato canonico;
  # il testo tecnico e il Markdown sono proiezioni generate, non una seconda sorgente da mantenere.
  class PlanDocument
    MACHINE_KEYS = %w[id path line dependencies].freeze
    RISK_LEVELS = %w[none low high].freeze
    HIGH_RISK_PATHS = %w[db/migrate/ config/deploy .github/workflows/].freeze
    attr_reader :plan

    def initialize(plan)
      @plan = plan
    end

    def legacy? = plan.contract_version.to_i < 2 || !plan.content.is_a?(Hash) || plan.content.blank?
    def summary = legacy? ? plan.technical_analysis : plan.content["summary"].to_s
    # CYRA-702 — poche frasi in linguaggio semplice per chi approva dalla coda. Solo se l'agente
    # l'ha scritto: la card ripiega sulla sintesi, mai su un testo inventato qui.
    def decision_brief = plan.decision_brief.presence

    # CYRA-885 — the card the agent wrote for the approver, read from its result (nil for plans without
    # one). The server may raise the stated risk, never lower it.
    def decision_card
      card = plan.attempt&.result.to_h["decision_card"]
      return unless card.is_a?(Hash) && card["headline"].present?

      card.slice("headline", "points", "risk").merge("risk_level" => raised_risk_level(card["risk_level"]))
    end

    def work_items = legacy? ? [] : array("work_items")
    def rationale = legacy? ? [] : array("rationale")
    def risks = legacy? ? [] : array("risks")
    def open_points = legacy? ? [] : array("open_points")
    def sources = legacy? ? [] : array("sources")

    def scenarios
      Array(plan.scenarios).filter_map do |scenario|
        next unless scenario.is_a?(Hash)

        scenario.deep_stringify_keys.slice("id", "title", "given", "when", "then", "expected")
      end
    end

    def definition_of_done
      Array(plan.definition_of_done).filter_map do |criterion|
        case criterion
        when Hash then criterion.deep_stringify_keys.slice("id", "text")
        when String then { "id" => nil, "text" => criterion }
        end
      end
    end

    def technical_analysis
      return plan.technical_analysis if legacy?

      self.class.technical_analysis(plan.content)
    end

    def self.technical_analysis(content)
      data = content.to_h.deep_stringify_keys
      lines = [ data["summary"].to_s ]
      section(lines, "Interventi", Array(data["work_items"])) do |item|
        heading = [ item["id"], item["title"] ].compact_blank.join(" · ")
        [ "#### #{heading}", item["description"], files(item["files"]), dependencies(item["dependencies"]) ]
      end
      simple_section(lines, "Perché", data["rationale"])
      section(lines, "Rischi", Array(data["risks"])) do |risk|
        [ "- **#{[ risk["id"], risk["title"] ].compact_blank.join(" · ")}** — #{risk["impact"]}",
          risk["mitigation"].present? ? "  Mitigazione: #{risk["mitigation"]}" : nil ]
      end
      simple_section(lines, "Punti aperti", data["open_points"])
      section(lines, "Fonti", Array(data["sources"])) do |source|
        [ "- `#{coordinate(source)}` — #{source["reason"]}" ]
      end
      lines.flatten.compact_blank.join("\n\n")
    end

    # Corregge la prosa senza alterare coordinate e identificatori. `correct_deep` su tutto il JSON
    # trasformerebbe, per esempio, un segmento di path `/gia/` in `/già/`.
    def self.normalize_content(value)
      case value
      when String then Text::ItalianOrthography.correct(value)
      when Array then value.map { |item| normalize_content(item) }
      when Hash
        value.each_with_object({}) do |(key, item), normalized|
          normalized[key.to_s] = MACHINE_KEYS.include?(key.to_s) ? item : normalize_content(item)
        end
      else value
      end
    end

    class << self
      private

      def section(lines, title, items)
        return if items.blank?

        lines << "### #{title}"
        items.each { |item| lines.concat(Array(yield(item.to_h.deep_stringify_keys))) }
      end

      def simple_section(lines, title, items)
        return if Array(items).blank?

        lines << "### #{title}"
        Array(items).each { |item| lines << "- #{item}" }
      end

      def files(items)
        return if Array(items).blank?

        [ "File coinvolti:", *Array(items).map do |file|
          file = file.to_h.deep_stringify_keys
          "- `#{coordinate(file)}` — #{file["reason"]}"
        end ].join("\n")
      end

      def dependencies(items)
        return if Array(items).blank?

        "Dipendenze: #{Array(items).join(", ")}"
      end

      def coordinate(item)
        [ item["path"], item["line"] ].compact_blank.join(":")
      end
    end

    private

    def array(key) = Array(plan.content[key])

    def raised_risk_level(stated)
      levels = [ RISK_LEVELS.index(stated).to_i ]
      levels << 1 if risks.any?
      levels << 2 if touches_high_risk_paths?
      RISK_LEVELS[levels.max]
    end

    def touches_high_risk_paths?
      work_items.flat_map { |item| Array(item.to_h["files"]) }.any? do |file|
        HIGH_RISK_PATHS.any? { |prefix| file.to_h["path"].to_s.start_with?(prefix) }
      end
    end
  end
end
