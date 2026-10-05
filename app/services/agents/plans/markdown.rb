# frozen_string_literal: true

module Agents
  module Plans
    # Esporta la stessa sorgente strutturata mostrata a video. Non esiste un file .md indipendente
    # che possa divergere dal piano approvato: il documento viene composto quando serve.
    class Markdown
      def self.call(plan:, ticket:)
        document = plan.document
        lines = [ "# Piano #{ticket.code} · v#{plan.version}", "", document.summary ]
        append_work_items(lines, document.work_items)
        append_list(lines, "Perché", document.rationale)
        append_risks(lines, document.risks)
        append_list(lines, "Punti aperti", document.open_points)
        append_sources(lines, document.sources)
        append_scenarios(lines, document.scenarios)
        append_done(lines, document.definition_of_done)
        append_list(lines, "Note", plan.notes)
        "#{lines.join("\n").rstrip}\n"
      end

      class << self
        private

        def append_work_items(lines, items)
          return if items.blank?

          lines.concat([ "", "## Interventi" ])
          items.each do |raw|
            item = raw.to_h.deep_stringify_keys
            lines.concat([ "", "### #{[ item["id"], item["title"] ].compact_blank.join(" · ")}",
                           item["description"] ])
            Array(item["files"]).each do |raw_file|
              file = raw_file.to_h.deep_stringify_keys
              coordinate = [ file["path"], file["line"] ].compact_blank.join(":")
              lines << "- `#{coordinate}` — #{file["reason"]}"
            end
            lines << "- Dipende da: #{Array(item["dependencies"]).join(", ")}" if Array(item["dependencies"]).present?
          end
        end

        def append_list(lines, title, items)
          return if Array(items).blank?

          lines.concat([ "", "## #{title}", *Array(items).map { |item| "- #{item}" } ])
        end

        def append_risks(lines, items)
          return if items.blank?

          lines.concat([ "", "## Rischi" ])
          items.each do |raw|
            risk = raw.to_h.deep_stringify_keys
            lines << "- **#{[ risk["id"], risk["title"] ].compact_blank.join(" · ")}** — #{risk["impact"]}"
            lines << "  Mitigazione: #{risk["mitigation"]}" if risk["mitigation"].present?
          end
        end

        def append_sources(lines, items)
          return if items.blank?

          lines.concat([ "", "## Fonti" ])
          items.each do |raw|
            source = raw.to_h.deep_stringify_keys
            coordinate = [ source["path"], source["line"] ].compact_blank.join(":")
            lines << "- `#{coordinate}` — #{source["reason"]}"
          end
        end

        def append_scenarios(lines, scenarios)
          return if scenarios.blank?

          lines.concat([ "", "## Scenari" ])
          scenarios.each do |scenario|
            lines << "- **Dato** #{scenario["given"]}, **quando** #{scenario["when"]}, " \
                     "**allora** #{scenario["then"]}, **mi aspetto** #{scenario["expected"]}."
          end
        end

        def append_done(lines, criteria)
          return if criteria.blank?

          lines.concat([ "", "## Definizione di fatto" ])
          criteria.each do |criterion|
            label = criterion["id"].present? ? "**#{criterion["id"]}** — " : ""
            lines << "- [ ] #{label}#{criterion["text"]}"
          end
        end
      end
    end
  end
end
