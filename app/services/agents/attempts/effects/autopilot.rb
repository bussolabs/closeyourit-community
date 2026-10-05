# frozen_string_literal: true

module Agents
  module Attempts
    module Effects
      class Autopilot < Base
        # `already-delivered` avanza come `delivered`: il lavoro È consegnato, solo da una sessione
        # precedente — il contratto lo lascia dire soltanto con la PR come prova. Trattarlo diversamente
        # lascerebbe il ticket in coda a ripetere all'infinito una lavorazione già compiuta, che è
        # esattamente ciò che accadeva quando l'agente, non avendo lo stato, usciva dallo schema.
        ADVANCING_STATES = %w[delivered already-delivered].freeze

        # CYRA-614 — la verifica parte subito DOPO il commit, non dentro la transazione: dentro
        # terrebbe righe bloccate per la durata di una chiamata a GitHub, ed è la ragione per cui il
        # confronto con lo stato vivo della proposta non sta in questo pezzo.
        def after_commit
          Agents::CandidateVerificationJob.perform_later(@candidate.id) if @candidate
        end

        private

        def apply!
          return block_from_agent! if result_state == "blocked"
          return unless result_state.in?(ADVANCING_STATES)

          # CYRA-612 — la consegna fa UNA cosa: prende nota di dove sta la proposta e lo scrive in un
          # registro che resta. Non sposta più il lavoro e non chiede niente a nessuno.
          #
          # Prima il lavoro entrava nella pila delle decisioni nell'istante in cui la macchina diceva «ho
          # finito» — e lo dicevano in due, senza che nessuno dei due avesse guardato: la skill spostava
          # il ticket da sé, e poi questo servizio lo spostava di nuovo appena riceveva il rapporto.
          # Nessuno aveva aperto la proposta, letto il codice, guardato l'esito dei controlli. Chi
          # approvava si trovava davanti una cosa che il sistema non aveva mai visto.
          #
          # `autopilot_completed_at` RESTA, e non è una svista: è il marcatore di conclusione che
          # `reopen_execution_phase!` legge. Senza, un host morto a metà riapre l'autopilot e la macchina
          # apre una SECONDA proposta sullo stesso lavoro.
          record_delivery_candidate!
          workflow.update!(autopilot_completed_at: Time.current)
        end

        # La riga del registro: `pending`, da ricontrollare subito. Niente `head_sha` né `base_ref` —
        # quelli si congelano leggendo la risposta di GitHub, che qui non si interroga.
        #
        # Idempotente sulla terna (lavorazione, progetto, numero): una seconda consegna della stessa
        # proposta non fa una seconda riga. L'indice unico la coprirebbe comunque (`nulls_not_distinct`
        # rende uguali due `head_sha` nulli), ma farlo esplicitamente evita che una consegna ripetuta
        # esca come errore di database invece che come la cosa innocua che è.
        def record_delivery_candidate!
          coordinate = PullRequestUrl.coordinates(payload.dig("result", "delivery", "prUrl")) or return

          repository = Github::Repository.joins(project: :organization)
                                         .find_by(full_name: coordinate[:full_name],
                                                  projects: { organization_id: workflow.organization.id })
          @candidate = Agents::DeliveryCandidate.find_or_create_by!(
            workflow:, repository_full_name: coordinate[:full_name], number: coordinate[:number], head_sha: nil
          ) do |candidate|
            candidate.attempt = attempt
            candidate.repository = repository
            candidate.state = :pending
            candidate.next_check_at = Time.current
          end
        end
      end
    end
  end
end
