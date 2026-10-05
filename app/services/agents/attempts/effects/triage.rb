# frozen_string_literal: true

module Agents
  module Attempts
    module Effects
      # Il commento con le domande lo pubblica il SERVER, nella stessa transazione del record (CYRA-215).
      # Lo postava la skill, ma nella sessione sandboxata non esiste comando con cui farlo: i guardrail
      # rifiutano `?`, graffe ed espansioni in qualunque comando, e le fasi read non hanno un worktree in
      # cui scriverlo su file. Le domande restavano nel solo record strutturato e nessuno le vedeva mai.
      # Scriverlo qui chiude anche la finestra in cui una risposta umana arrivava prima della Clarification
      # a cui agganciarsi, e permette di valorizzare question_comment (prima sempre nil).
      # workable avanza la coda; waiting/escalated restano fermi.
      class Triage < Base
        # La notifica parte DOPO il commit, o il job potrebbe girare su un commento non ancora visibile —
        # è la stessa ragione per cui Ticketing::AddComment tiene notify/broadcast fuori da transazioni
        # esterne. Una domanda che non avvisa nessuno resta senza risposta, e la lavorazione ferma per sempre.
        def after_commit
          return if @clarification.nil?

          Ticketing::CommentNotifyJob.perform_later(
            comment_id: @clarification.question_comment_id, mentioned_ids: []
          )
        end

        private

        def apply!
          case result_state
          when "workable"
            workflow.update!(triaged_at: Time.current)
          when "needs-clarification"
            @clarification = Agents::Clarifications::Ask.call(
              workflow: workflow, attempt: attempt,
              questions: payload.dig("result", "questions"), author: host.service_account
            ).value
          when "waiting", "escalated"
            # CYRA-598 — prima il server accettava questa risposta e poi non faceva niente. Da quel
            # momento la lavorazione restava scritta come in corso per sempre: il claim aveva già
            # scritto triage_started_at e nessun marcatore di conclusione si muoveva, quindi non
            # tornava in coda, non compariva fra quelle che aspettano una persona, e la scheda diceva
            # che non serviva niente. L'unica uscita era annullarla.
            block_from_agent!
          end
        end
      end
    end
  end
end
