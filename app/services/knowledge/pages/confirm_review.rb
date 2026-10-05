# frozen_string_literal: true

module Knowledge
  module Pages
    # CYRA-768 — «questa pagina è ancora vera»: la conferma che fa ripartire il conto senza toccare
    # il testo. È il quarto passaggio della revisione, e come i primi due lo compie una PERSONA
    # (ReviewGuards#human_actor?): dire «è ancora vero» è un giudizio, e una macchina che si
    # autoconfermasse svuoterebbe di senso la scadenza — la coda si azzererebbe da sé, ogni notte,
    # senza che nessuno abbia riletto niente.
    #
    # La via d'uscita per le macchine c'è ed è naturale: se una riscrive il TESTO, il conto riparte
    # da sé in Knowledge::UpdatePage, perché il contenuto è cambiato ed è ripassato dal revisore
    # automatico. È la conferma «a vuoto» a chiedere una persona.
    #
    # Non tocca `reviewed_at`/`reviewed_by`: quelli dicono chi ha ACCETTATO la proposta e reggono
    # `awaiting_consolidation`. Riscriverli qui farebbe comparire fra le «accettate da mettere nei
    # documenti» ogni pagina scritta a mano dal web che qualcuno conferma.
    class ConfirmReview < ApplicationService
      include ReviewGuards

      def initialize(page:, actor:)
        @page = page
        @actor = actor
      end

      def call
        return machine_decision unless human_actor?
        return wrong_status(:not_published) unless @page.status_published?
        # Nessuna data, o data non ancora arrivata: non c'è niente da far ripartire. Confermare una
        # nota le inventerebbe una scadenza che il suo tipo non prevede.
        return wrong_status(:nothing_to_confirm) unless @page.needs_review?
        return forbidden unless manageable?

        # update_columns e non update!: confermare NON è modificare la pagina. Toccare `updated_at`
        # la farebbe risalire in cima a ogni elenco (ordinati per quella colonna) come se qualcuno
        # ne avesse riscritto il testo — una modifica fantasma, senza nemmeno una versione dietro.
        @page.update_columns(review_after: Knowledge::ReviewSchedule.next_for(kind: @page.kind))
        Result.ok(@page)
      end
    end
  end
end
