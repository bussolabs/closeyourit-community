# frozen_string_literal: true

module Agents
  module Attempts
    # Canale di consegna dell'esito FALLITO (CYRA-282). `failed` era nell'enum e in TERMINAL_STATUSES ma
    # nessun percorso in app/ lo scriveva: quando la sessione moriva sulla macchina, l'automator rilasciava
    # il lease e riclaimava, quindi SAPEVA di aver fallito ma non aveva un canale per dirlo. Un guasto
    # restava indistinguibile da una macchina spenta e poteva andare avanti per giorni.
    #
    # Speculare a MarkStale (l'orfano potato dal server) e a Deliver (l'esito riuscito/bocciato): qui la
    # MACCHINA riporta attivamente il proprio guasto col motivo. Come MarkStale, riapre la fase interrotta
    # (reopen_execution_phase!) così il ticket rientra SUBITO in coda invece di aspettare il giro periodico
    # degli orfani — ma la riapertura da sola non basta: se il lease di QUESTA lavorazione resta vivo, il
    # ticket è "pronto" eppure non reclamabile finché il lease non scade, e una consegna /result tardiva
    # supererebbe lock_scope! per poi morire su update! di un attempt terminale (ReadOnlyRecord → HTTP 500).
    # Quindi nella stessa transazione si ritira anche il lease della lavorazione fallita (host-owned, stessa
    # run): il ticket torna reclamabile davvero e la consegna tardiva fallisce pulita (lease assente → stale).
    #
    # Autorità: un host può marcare fallito SOLO un tentativo che ha eseguito (match su host_id). Nessun
    # lease-match come precondizione: la sessione morente ha il lease magari già scaduto, e pretenderlo
    # attivo bloccherebbe il report proprio quando serve.
    class ReportFailure < ApplicationService
      def initialize(host:, attempt:, reason:)
        @host = host
        @attempt = attempt
        @reason = reason.to_s.strip
      end

      def call
        return not_owner unless @attempt.host_id == @host.id
        return blank_reason if @reason.blank?

        ApplicationRecord.transaction do
          @attempt.lock!
          # Rivalutazione sotto lock: una consegna può essere arrivata tra il controllo e adesso. Un
          # tentativo già `failed` è un replay idempotente (la macchina riprova la chiamata); qualunque
          # altro terminale è un esito già registrato che il report NON deve sovrascrivere.
          next Result.ok(@attempt) if @attempt.status_failed?
          next already_concluded unless @attempt.status_running?

          @attempt.update!(status: :failed, failure_reason: truncated_reason, finished_at: Time.current)
          # Recovery della coda (gemello di MarkStale): riapre la fase avviata e mai conclusa così il ticket
          # torna proposto alle macchine invece di restare fuori dalla coda.
          @attempt.workflow.reopen_execution_phase!(@attempt.phase)
          # …ma non all'infinito (CYRA-504): un guasto che si ripete è una lavorazione da guardare, non da
          # riprovare per sempre. Il tetto viveva sulla sola strada della consegna e questa non ci passa,
          # quindi qui nessun conteggio si muoveva. Dopo la riapertura: il blocco la spegne comunque, e
          # allo sblocco la fase riparte perché lo start è già azzerato.
          Agents::Workflows::BlockExhaustedPhase.call(attempt: @attempt)
          release_lease!
          Result.ok(@attempt)
        end
      end

      private

      # Ritira il lease della lavorazione fallita, SOLO se è un lease host di QUESTA run (mai un lease umano,
      # mai un lease fresco di un'altra lavorazione dello stesso ticket): senza, il ticket resta bloccato dal
      # lease vivo nonostante la fase riaperta, e una consegna /result tardiva esploderebbe su un attempt
      # ormai terminale. Come Workflows::Cancel: distrugge la riga (l'indice su ticket_id la riusa al claim).
      def release_lease!
        lease = @attempt.workflow.ticket.agent_lease
        return unless lease && !lease.human? &&
                      lease.host_id == @host.id && lease.run_id == @attempt.external_run_id

        lease.destroy!
      end

      def truncated_reason = @reason[0, Agents::Constants::FAILURE_REASON_MAX]

      def not_owner
        Result.err(AppError.new("Tentativo non eseguito da questo host",
                                code: "R409-ATTEMPT-001", status: :conflict))
      end

      def already_concluded
        Result.err(AppError.new("Il tentativo è già concluso con un altro esito",
                                code: "R409-ATTEMPT-004", status: :conflict))
      end

      def blank_reason
        Result.err(AppError.new("Il motivo del fallimento è obbligatorio",
                                code: "R422-ATTEMPT-002", status: :unprocessable_content))
      end
    end
  end
end
