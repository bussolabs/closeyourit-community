# frozen_string_literal: true

module Secrets
  module Attention
    # La lista «Da sistemare» (CYRA-428): mette in UNA sola sequenza ordinata per rischio le tre cose
    # che prima vivevano su tre pagine diverse — le anomalie dei secret («Cosa non torna»), i secret
    # con la rotazione scaduta o vicina («Rotazione») e le richieste di modifica in attesa di una
    # decisione («Modifiche ai segreti»). Tre pagine che rispondevano tutte alla stessa domanda —
    # cosa devo fare adesso — e due delle quali erano quasi sempre vuote.
    #
    # Non interroga il database: riceve ciò che i report esistenti hanno già raccolto
    # (Secrets::Health::Report, Secrets::RotationReport, Secrets::ChangeRequests::Pending) e decide
    # soltanto quanto pesa ciascuna cosa e in che ordine si legge. Così i gate restano dove sono —
    # chi non può vedere le anomalie semplicemente non ne passa nessuna — e il costo in query non
    # cambia rispetto alle tre pagine di prima.
    class Report
      # Tre livelli, non un punteggio: la lista deve dire in una parola quanto è grave, e chi la
      # legge deve poter rifare l'ordinamento a mente. La produzione alza sempre di un livello: è la
      # sola dimensione che cambia le conseguenze di un segreto sbagliato.
      RISK_RANK = { high: 3, medium: 2, low: 1 }.freeze

      # A parità di rischio conta quanto si è vicini alla rottura: una variabile che MANCA rompe
      # adesso, una scaduta è fuori regola da un pezzo, una in scadenza è ancora in tempo, e una
      # richiesta in attesa non rompe nulla — aspetta una persona.
      # CYRA-777 — «valore in comune» chiude la fila: non rompe niente, non blocca niente e non ha
      # una scadenza. È l'unica riga che propone un miglioramento invece di segnalare un guasto, e per
      # questo non deve mai stare sopra a qualcosa che è rotto adesso.
      KIND_ORDER = { anomaly: 0, rotation_overdue: 1, rotation_due_soon: 2, change_request: 3,
                     consolidation: 4 }.freeze

      # Ambiente di produzione: il code convenzionale del seed (stessa regola di
      # Secrets::Health::AnomalyRow, che non possiamo riusare perché qui gli oggetti sono di tre tipi).
      PRODUCTION_CODE = "production"

      # Una riga della lista, qualunque sia la sua provenienza. `source` porta l'oggetto originale
      # (la riga di anomalia, la variabile, la richiesta): la vista ci pesca l'azione giusta per quel
      # tipo, senza che il report debba conoscere i bottoni.
      # `project` è nil sulle righe di consolidamento, ed è l'unico caso: un valore ripetuto in più
      # progetti non appartiene a nessuno di loro, e sceglierne uno da mostrare racconterebbe una
      # cosa falsa. La vista rende il conteggio al suo posto.
      Item = Data.define(:kind, :risk, :project, :environment, :secret_name, :since, :source) do
        def production? = environment&.code == PRODUCTION_CODE

        # Rischio decrescente, poi vicinanza alla rottura, poi la più vecchia; il nome chiude
        # l'ordine perché due righe identiche in tutto non si scambino di posto a ogni caricamento.
        def rank = [ -RISK_RANK.fetch(risk), KIND_ORDER.fetch(kind), since, secret_name.to_s ]
      end

      def initialize(anomaly_rows: [], rotation_variables: [], change_requests: [], consolidations: [])
        @anomaly_rows = anomaly_rows
        @rotation_variables = rotation_variables
        @change_requests = change_requests
        @consolidations = consolidations
      end

      # Tutto da sistemare in una lista sola, dal più rischioso al meno.
      def items
        @items ||= (anomaly_items + rotation_items + change_request_items + consolidation_items).sort_by(&:rank)
      end

      def any? = items.any?
      def count = items.size
      def high_count = items.count { |item| item.risk == :high }

      # Quante righe di un certo tipo: alimenta le chip dell'header senza che la vista rifaccia i conti.
      def count_for(kind) = items.count { |item| item.kind == kind }

      private

      # Un'anomalia è una variabile che manca dove dovrebbe esserci: in produzione è il rischio più
      # alto della lista, altrove resta media.
      def anomaly_items
        @anomaly_rows.map do |row|
          build(kind: :anomaly, environment: row.environment, project: row.project,
                secret_name: row.secret_name, since: row.first_seen_at, source: row,
                risk: production?(row.environment) ? :high : :medium)
        end
      end

      # Una rotazione scaduta pesa come un'anomalia (il valore è fuori regola da giorni); una in
      # scadenza è ancora in tempo e scende di un livello. Le variabili senza regola, o con la
      # scadenza lontana, non sono cose da sistemare adesso: restano fuori dalla lista (org-wide
      # sarebbero migliaia, vedi Secrets::RotationReport#uncovered_preview).
      def rotation_items
        @rotation_variables.filter_map do |variable|
          overdue = variable.rotation_status == :overdue
          next unless overdue || variable.rotation_status == :due_soon

          in_production = production?(variable.environment)
          build(kind: overdue ? :rotation_overdue : :rotation_due_soon, environment: variable.environment,
                project: variable.project, secret_name: variable.name, since: variable.rotate_by,
                source: variable, risk: rotation_risk(overdue: overdue, in_production: in_production))
        end
      end

      # Una richiesta in attesa non rompe niente da sola: blocca un cambiamento finché qualcuno non
      # decide. Sta in fondo al suo livello, ma in produzione sale comunque di un gradino.
      def change_request_items
        @change_requests.map do |change_request|
          build(kind: :change_request, environment: change_request.environment,
                project: change_request.project, secret_name: change_request.name,
                since: change_request.created_at, source: change_request,
                risk: production?(change_request.environment) ? :medium : :low)
        end
      end

      # Un valore ripetuto non rompe niente oggi: rompe il giorno in cui qualcuno lo cambia in un
      # posto solo, e in produzione quel giorno costa di più. Da qui il gradino, come per tutte le
      # altre righe della lista.
      def consolidation_items
        @consolidations.map do |suggestion|
          build(kind: :consolidation, environment: suggestion.environment, project: nil,
                secret_name: suggestion.suggested_name, since: suggestion.first_seen_at,
                source: suggestion, risk: production?(suggestion.environment) ? :medium : :low)
        end
      end

      def rotation_risk(overdue:, in_production:)
        return in_production ? :high : :medium if overdue

        in_production ? :medium : :low
      end

      def build(**attributes) = Item.new(**attributes)

      def production?(environment) = environment&.code == PRODUCTION_CODE
    end
  end
end
