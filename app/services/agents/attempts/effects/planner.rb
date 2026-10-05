# frozen_string_literal: true

module Agents
  module Attempts
    module Effects
      # CYRA-598 — la guardia sullo stato non è pulizia, è la condizione perché il ramo `blocked`
      # possa esistere. Questi `fetch` sono a secco: reggevano solo perché lo schema garantiva i
      # quattro campi. Nel momento esatto in cui il contratto accetta `blocked` — che quei campi non
      # li ha — la prima consegna bloccata solleva KeyError dentro la transazione della consegna.
      class Planner < Base
        def after_commit
          Agents::PlanReadyNotificationJob.perform_later(@plan.id) if @plan
        end

        private

        def apply!
          return apply_already_done! if result_state == "already-done"
          return block_from_agent! unless result_state == "submitted-for-approval"

          result = payload.fetch("result")
          structured = result["contract_version"] == 2
          content = structured ? result.fetch("plan") : {}
          @plan = Agents::Plan.create!(
            workflow: workflow, attempt: attempt, contract_version: structured ? 2 : 1, content:,
            decision_brief: (result["decision_brief"] if structured),
            technical_analysis: structured ? Agents::PlanDocument.technical_analysis(content) : result.fetch("technical_analysis"),
            scenarios: result.fetch("scenarios"),
            definition_of_done: result.fetch("definition_of_done"), mixed_parts: result["mixed_parts"],
            notes: result.fetch("notes"), ticket_snapshot_digest: workflow.ticket_snapshot_digest
          )
          workflow.update!(planned_at: Time.current)
        end

        # CYRA-675 — «era già fatto». Chi doveva pianificare è andato a guardare il codice di oggi e ha
        # trovato il lavoro già presente nel ramo principale: non c'è un piano da scrivere, e il ticket
        # si chiude qui.
        #
        # È l'unico punto del sistema in cui una consegna chiude un ticket da sola, quindi le difese
        # stanno tutte a monte e sono già passate quando si arriva a questa riga: lo schema pretende
        # `already_done.summary` e almeno una `source` (chiudere sulla parola non si può), e il
        # contratto della consegna pretende il sì della rilettura incrociata dal runtime opposto. Qui
        # resta da eseguire, non da giudicare.
        #
        # Gira DENTRO la transazione della consegna, dove ticket, lavorazione e progetto sono già
        # bloccati da Attempts::Deliver#lock_scope!.
        def apply_already_done!
          ticket = workflow.ticket
          status = done_status
          # Un'organizzazione senza uno stato conclusivo attivo non è un caso da ignorare in silenzio: il
          # lavoro è finito e il ticket resterebbe aperto per sempre, riproposto al planner a ogni giro.
          return block_already_done!("stato conclusivo non configurato") if status.nil?
          # Prerequisiti ancora aperti: la traccia dice quali (record_dependency_block), e la lavorazione
          # si ferma invece di riprovare a chiudere all'infinito.
          return if dependency_blocked!(ticket, status) { block_already_done!("prerequisiti aperti") }

          outcome = Ticketing::ChangeStatus.call(organization: workflow.organization, ticket: ticket,
                                               status_id: status.id, channel: :workflow, actor: attempt_author)
          return block_already_done!(outcome.error.message) if outcome.err?

          @already_done_comment = ticket.comments.create!(body: already_done_body(ticket),
                                                          author: attempt_author, kind: :service)
          Ticketing::RecordActivity.call(
            ticket: ticket, actor: attempt_author, action: "already_done",
            data: { summary: already_done.fetch("summary"), sources: already_done.fetch("sources"),
                    comment_id: @already_done_comment.id }
          )
          workflow.update!(completed_at: Time.current)
        end

        def already_done = payload.fetch("result").fetch("already_done")

        def done_status
          workflow.organization.ticket_statuses.active.category_done.ordered.first
        end

        # Fermarsi invece di chiudere. La consegna resta valida e registrata — l'agente ha fatto il suo
        # lavoro e ha guardato davvero — ma il ticket non si sposta e una persona viene chiamata: fra il
        # dire «è già fatto» e il poterlo dichiarare concluso c'è di mezzo la configurazione del
        # progetto, che non è colpa di chi ha guardato.
        def block_already_done!(reason)
          Agents::Workflows::Block.call(
            workflow: workflow, phase: "planner", kind: "agent_blocked",
            reason: "agent_blocked: il lavoro risulta già fatto ma il ticket non si è potuto chiudere — #{reason}"
          )
        end

        # Riga di servizio a lunghezza FISSA, come per la domanda di chiarimento: un commento sta in
        # Ticketing::Constants::COMMENT_MAX_CHARS caratteri e il riassunto dell'agente non ha un tetto, quindi
        # interpolarlo qui farebbe fallire la validazione dentro la transazione della consegna — cioè 500
        # sulla consegna e ticket fermo per sempre. Il riassunto per intero sta nella scheda Automazione,
        # i file provati nella cronologia. La lingua è quella di chi ha aperto il ticket: lo legge una
        # persona, non la macchina.
        def already_done_body(ticket)
          I18n.with_locale(ticket.reporter&.effective_locale || I18n.default_locale) do
            I18n.t("agents.already_done.service_line")
          end
        end

        # Il cancello, e cosa si fa quando è chiuso. Gira DENTRO la transazione della consegna, dove il
        # ticket è già bloccato da Attempts::Deliver#lock_scope!: stesso ordine di ApproveAutopilot, quindi
        # nessun deadlock e nessuna finestra fra il controllo e la scrittura.
        #
        # Quando blocca non solleva: la consegna resta valida e registrata: il lavoro è stato fatto
        # davvero, e buttarlo obbligherebbe a rifarlo. Si ferma solo lo STATO, e resta scritto perché.
        def dependency_blocked!(ticket, target_status)
          outcome = Ticketing::DependencyGuard.call(ticket:, target_category: target_status.category)
          return false if outcome.ok?

          yield if block_given?
          record_dependency_block(ticket, outcome)
          true
        end

        # La traccia. Senza, un ticket si ferma e nessuno sa dire perché: è la differenza fra «si è
        # fermato» e «si è fermato per colpa di quest'altro». I codici dei prerequisiti aperti li porta
        # già l'errore del cancello.
        def record_dependency_block(ticket, outcome)
          Ticketing::RecordActivity.call(
            ticket:, actor: attempt_author, action: "dependency_blocked",
            data: { dependencies: Array(outcome.error.details[:dependencies]),
                    open_count: outcome.error.details[:open_count] }
          )
        end
      end
    end
  end
end
