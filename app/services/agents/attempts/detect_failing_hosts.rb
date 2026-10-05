# frozen_string_literal: true

module Agents
  module Attempts
    # CYRA-282 — "una macchina butta via il lavoro": un host che fallisce una quota anomala di lavorazioni
    # nella finestra genera un avviso PER-HOST (`agents_host_failing`). Accoda l'allarme via Alerting.
    #
    # È il complemento di DetectStalled, non un doppione: quello è org-scoped e scatta sull'ASSENZA DI
    # PROGRESSO (zero `approved` nell'org). Il caso reale di questo ticket — una delle due macchine con
    # l'88% dei tentativi falliti mentre l'altra lavorava — NON lo farebbe scattare: l'org progrediva. Solo
    # guardando il singolo host emerge il guasto. Qui il segnale è la QUOTA di `failed` (guasto tecnico
    # riportato dalla macchina), non gli altri esiti di spreco: una bocciatura è un giudizio sul lavoro, un
    # orfano è una finestra persa, un annullamento è volontario — nessuno è la macchina che si rompe.
    #
    # Due guardie contro il rumore: un volume minimo (1 fallito su 1 è 100% ma non dice niente) e una quota
    # minima sul totale dei tentativi terminali dell'host nella finestra. Idempotente: l'anti-spam
    # dell'alerting (throttle/dedup per regola e subject) collassa i giri ripetuti in una notifica.
    class DetectFailingHosts < ApplicationService
      def initialize(now: Time.current, window: Agents::Constants::HOST_FAILURE_WINDOW)
        @now = now
        @since = now - window
      end

      def call
        host_ids = failing_host_ids
        return Result.ok(0) if host_ids.empty?

        flagged = 0
        # Solo host ATTIVI (non revocati): un host dismesso e i suoi guasti storici non sono un allarme da
        # riaprire. Il filtro `active` è l'unica query oltre all'aggregato — niente 1+2N per host candidato.
        Agents::Host.active.where(id: host_ids).find_each do |host|
          Alerting::EvaluateJob.perform_later(
            event_type: "agents_host_failing", subject_type: "Agents::Host",
            subject_id: host.id, project_id: nil, organization_id: host.organization_id
          )
          flagged += 1
        end
        Result.ok(flagged)
      end

      private

      # Host che superano quota e volume, in UNA query aggregata sui terminali della finestra: conteggio
      # dei `failed` (numeratore) e di tutti i terminali (denominatore) per host via FILTER. Il denominatore
      # è la stessa partizione che legge la pagina dell'host (Performance): un host sano ha tanti `approved`
      # e la quota resta bassa; uno guasto ha quasi solo `failed`. La soglia si applica in Ruby sulle poche
      # righe aggregate. L'id dello status arriva dall'enum del model (sicuro da interpolare, come Performance).
      def failing_host_ids
        failed_id = Agents::Attempt.statuses.fetch("failed")
        Agents::Attempt
          .where(finished_at: @since..@now, status: Agents::Attempt::TERMINAL_STATUSES)
          .group(:host_id)
          .pluck(:host_id, Arel.sql("COUNT(*) FILTER (WHERE status = #{failed_id})"), Arel.sql("COUNT(*)"))
          .filter_map { |host_id, failed, total| host_id if failing?(failed, total) }
      end

      def failing?(failed, total)
        return false if failed < Agents::Constants::HOST_FAILURE_MIN
        return false if total.zero?

        (failed.to_f / total) >= Agents::Constants::HOST_FAILURE_RATIO
      end
    end
  end
end
