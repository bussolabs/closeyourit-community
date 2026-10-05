# frozen_string_literal: true

module Alerting
  module Rules
    # CYRA-490 — lo storico degli scatti di una regola per la sua pagina di sola lettura.
    #
    # `stats` conta le RIGHE di notifica (24h/7g/totale + ultimo), le stesse metriche della colonna
    # dell'index: chi arriva dalla tabella ritrova gli stessi numeri.
    #
    # `recent` risponde all'altra domanda — «su che cosa è scattata» — fondendo le consegne di UNO
    # stesso scatto in una sola voce. Il dispatch scrive una riga per (destinatario × canale) e, entro la
    # finestra di throttle, al più una per subject; quindi lo scatto è identificato da (subject, finestra)
    # con `finestra = created_at / throttle_seconds` (lo stesso bucket del dedup_key in Alerting::Evaluate).
    # Senza il raggruppamento la timeline mostrerebbe lo stesso avviso ripetuto una volta per destinatario
    # e per canale.
    class Triggers
      # Quante righe recenti scandire per comporre l'elenco: con molti destinatari uno scatto occupa più
      # righe, questo tetto tiene la vista "recenti" senza caricare tutto lo storico.
      SCAN_LIMIT = 200

      Stats = Data.define(:total, :last_24h, :last_7d, :last_at)
      # channels: i canali distinti su cui lo scatto è stato recapitato (valori di Alerting::Notification#via).
      Occurrence = Data.define(:title, :at, :channels)

      def self.stats(rule)
        scope = rule.notifications
        Stats.new(
          total: scope.count,
          last_24h: scope.where(created_at: 24.hours.ago..).count,
          last_7d: scope.where(created_at: 7.days.ago..).count,
          last_at: scope.maximum(:created_at)
        )
      end

      def self.recent(rule, limit: 8)
        window = rule.throttle_seconds.to_i
        window = 1 if window <= 0 # difesa da una riga legacy con throttle non valido: mai una divisione per zero

        rule.notifications.recent.limit(SCAN_LIMIT).to_a
            .group_by { |n| [ n.subject_type, n.subject_id, n.created_at.to_i / window ] }
            .map do |_key, group|
              Occurrence.new(title: group.first.title, at: group.map(&:created_at).max,
                             channels: group.map(&:via).uniq)
            end
            .sort_by(&:at).reverse.first(limit)
      end
    end
  end
end
