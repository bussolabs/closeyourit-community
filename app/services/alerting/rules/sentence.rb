# frozen_string_literal: true

module Alerting
  module Rules
    # CYRA-490 — la condizione di una regola scritta in una frase, GENERATA dai suoi campi. A mano
    # divergerebbe dalla configurazione reale appena la regola cambia (il rischio dichiarato nel ticket):
    # qui ogni pezzo esce dai dati. Compone segmenti i18n — lo stato reale (se non attiva), il trigger
    # (la descrizione dell'evento dal catalogo, il glossario UNICO del dominio), i qualificatori
    # applicabili (gravità, solo-non-gestiti, soglia), lo scope (progetto/ambiente o intera org) e il
    # raggruppamento — e li restituisce come array di frasi, che la view rende come un paragrafo.
    #
    # Quali qualificatori e quale scope valgono per l'evento si leggono da Alerting::Rule.fields_for,
    # la STESSA matrice che pilota il form (CYRA-481): la frase non può nominare un campo che il form non
    # ha permesso di impostare.
    class Sentence
      # Unità della soglia numerica per tipo evento: "%" e "°C" si attaccano al numero, connessioni e
      # secondi sono parole. La frase dice "oltre 90%", non "oltre 90".
      THRESHOLD_UNITS = {
        "server_cpu" => "%", "server_mem" => "%", "server_disk" => "%",
        "server_data_volume_disk" => "%", "server_db_connection_usage" => "%", "server_inode" => "%",
        "server_temp" => "°C",
        "server_db_connections" => :connections, "server_replication_lag" => :seconds
      }.freeze

      def self.call(rule) = new(rule).segments

      def initialize(rule)
        @rule = rule
        @fields = Alerting::Rule.fields_for(rule.event_type)
      end

      # Frasi compiute nell'ordine di lettura; i segmenti non pertinenti sono nil e cadono.
      def segments
        [ state_segment, trigger_segment, min_level_segment, unhandled_segment,
          threshold_ms_segment, threshold_segment, scope_segment, throttle_segment ].compact
      end

      # F109 — the same condition, short enough for the row of the rules list: "> 85%", "> 500 ms",
      # "Unhandled errors only". nil when the event has no qualifier beyond its scope and severity.
      def self.condition(rule) = new(rule).condition

      def condition
        parts = []
        parts << "> #{format('%g', rule.threshold_ms)} ms" if fields.include?("threshold_ms") && rule.threshold_ms
        parts << "> #{format('%g', rule.threshold)}#{threshold_unit}" if fields.include?("threshold") && rule.threshold
        parts << I18n.t("member.alerting.rules.form.unhandled_only_label") if fields.include?("unhandled_only") && rule.unhandled_only?
        parts.join(" · ").presence
      end

      private

      attr_reader :rule, :fields

      def t(key, **) = I18n.t("member.alerting.rules.show.sentence.#{key}", **)

      # Lo stato reale davanti a tutto: una regola può sembrare fare X ma essere spenta o silenziata, e
      # allora non nasce alcun avviso — è la prima cosa da dire per non ingannare chi legge.
      def state_segment
        return t(:state_off) unless rule.enabled?
        return t(:state_muted, time: I18n.l(rule.muted_until, format: :short)) if rule.muted?

        nil
      end

      # Il cuore della frase: la descrizione dell'evento dal catalogo unico. Fallback al nome leggibile
      # se un event_type non fosse a catalogo — una frase mancante non deve mai far esplodere la pagina.
      def trigger_segment
        ::Notifications::Catalog.entry(rule.event_type)&.description ||
          t(:trigger_fallback, event: I18n.t("member.alerting.event_types.#{rule.event_type}",
                                             default: rule.event_type.to_s.humanize))
      end

      def min_level_segment
        return unless fields.include?("min_level") && rule.min_level

        t(:min_level, level: I18n.t("member.alerting.levels.#{Alerting::Rule::LEVELS.key(rule.min_level)}"))
      end

      def unhandled_segment
        return unless fields.include?("unhandled_only") && rule.unhandled_only?

        t(:unhandled_only)
      end

      def threshold_ms_segment
        return unless fields.include?("threshold_ms") && rule.threshold_ms

        t(:threshold_ms, ms: rule.threshold_ms)
      end

      def threshold_segment
        return unless fields.include?("threshold") && rule.threshold

        t(:threshold, value: rule.threshold, unit: threshold_unit)
      end

      def threshold_unit
        case (unit = THRESHOLD_UNITS[rule.event_type])
        when :connections then " #{t(:threshold_connections)}"
        when :seconds then " #{t(:threshold_seconds)}"
        else unit.to_s
        end
      end

      # Scope: gli eventi org-scoped (la matrice del form non espone project_id) coprono tutta l'org;
      # gli altri nominano progetto e ambiente scelti, o "tutti / qualsiasi" quando lasciati aperti.
      def scope_segment
        return t(:scope_org) unless fields.include?("project_id")

        project = rule.project&.name
        environment = rule.environment&.label
        if project && environment
          t(:scope_project_env, project:, environment:)
        elsif project
          t(:scope_project, project:)
        elsif environment
          t(:scope_env, environment:)
        else
          t(:scope_all)
        end
      end

      def throttle_segment
        minutes = rule.throttle_seconds / 60
        t(:throttle, minutes: t(:minutes, count: minutes))
      end
    end
  end
end
