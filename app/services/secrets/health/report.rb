# frozen_string_literal: true

module Secrets
  module Health
    # Il modello di vista della pagina "Cosa non torna" (CYRA-409): trasforma le anomalie correnti
    # (Secrets::HealthCheck#anomalies) + la loro memoria persistita (mappa identity → Secrets::HealthAnomaly
    # di Secrets::Health::RecordAnomalies) in ciò che la pagina mostra:
    #   - `project_groups`: le anomalie ATTIVE raggruppate per progetto ed espandibili, ordinate per
    #     rischio (produzione prima, poi la più vecchia) — scenari 1 e 3;
    #   - `acknowledged`: le assenze marcate «volute», fuori dai conteggi ma consultabili — scenario 2.
    class Report
      # Un progetto con le sue anomalie attive: la riga che l'utente espande per leggere le variabili.
      ProjectGroup = Data.define(:project, :rows) do
        def risk_score = rows.map(&:risk_score).max || 0
        def oldest_first_seen = rows.map(&:first_seen_at).min
        def size = rows.size
        def production? = rows.any?(&:production?)
      end

      def initialize(anomalies:, records:)
        @rows = anomalies.filter_map do |anomaly|
          record = records[anomaly.identity]
          AnomalyRow.new(anomaly: anomaly, record: record) if record
        end
      end

      def any? = @rows.any?
      def active_count = active_rows.size
      def acknowledged_count = acknowledged_rows.size
      # Quante anomalie attive toccano un ambiente di produzione — la chip di rischio in cima.
      def production_active_count = active_rows.count(&:production?)

      # Quante anomalie attive di una certa categoria — per le chip di conteggio nell'header.
      def count_for(kind) = active_rows.count { |row| row.kind.to_s == kind.to_s }

      # Gruppi per progetto ordinati per rischio: prima il progetto con l'anomalia più grave (produzione),
      # a parità la più vecchia. Dentro ogni gruppo le righe sono già ordinate per rischio.
      def project_groups
        @project_groups ||= active_rows.group_by(&:project).map do |project, rows|
          ProjectGroup.new(project: project, rows: sort_rows(rows))
        end.sort_by { |group| [ -group.risk_score, group.oldest_first_seen ] }
      end

      # Le assenze volute, ordinate come le attive — la nota consultabile che resta dopo l'acknowledge.
      def acknowledged
        @acknowledged ||= sort_rows(acknowledged_rows)
      end

      private

      def active_rows = @active_rows ||= @rows.reject(&:acknowledged?)
      def acknowledged_rows = @acknowledged_rows ||= @rows.select(&:acknowledged?)

      # Rischio decrescente; a parità la più vecchia prima, poi progetto e nome per un ordine stabile.
      def sort_rows(rows)
        rows.sort_by { |row| [ -row.risk_score, row.first_seen_at, row.project.name.downcase, row.secret_name ] }
      end
    end
  end
end
