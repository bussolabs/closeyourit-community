# frozen_string_literal: true

module Knowledge
  module Pages
    # Accetta una proposta in revisione (CYRA-298): la pagina diventa pubblicata ed entra da quel
    # momento in ricerca, RAG, correlate e liste.
    #
    # È qui, e non alla creazione, che parte l'embedding: una proposta che verrà scartata non deve
    # costare una chiamata al servizio di embedding né occupare l'indice. Vedi Knowledge::CreatePage,
    # che per le pagine in revisione salta l'enqueue.
    #
    # Accettare NON significa consolidata: consolidated_at resta nil finché il documento non è
    # scritto nel repo della knowledge base (Knowledge::Pages::MarkConsolidated).
    #
    # Chi accetta è sempre una PERSONA: vedi ReviewGuards#human_actor? (CYRA-642).
    class Approve < ApplicationService
      include ReviewGuards

      def initialize(page:, actor:)
        @page = page
        @actor = actor
      end

      def call
        # Il guard umano viene PRIMA di tutto (CYRA-642): uscendo qui una macchina non cambia stato,
        # non firma la revisione e non accoda l'embedding, qualunque sia la pagina che ha puntato.
        return machine_decision unless human_actor?
        return wrong_status(:not_in_review) unless @page.status_in_review?
        return forbidden unless manageable?
        # CYRA-764: bocciata dal revisore automatico → prima si corregge (un salvataggio del testo
        # produce il verdetto nuovo), poi si accetta. Accettarla così com'è rimetterebbe in ricerca e
        # RAG esattamente la pagina che era stata tolta.
        return wrong_status(:ai_review_rejected) if @page.ai_review_rejected?

        # CYRA-768: da qui parte il conto della rilettura. Accettare è il momento in cui la pagina
        # diventa vera per tutti, quindi è il momento giusto per dire fino a quando.
        @page.update!(status: :published, reviewed_by: @actor, reviewed_at: Time.current,
                      review_after: Knowledge::ReviewSchedule.next_for(kind: @page.kind))
        Knowledge::EmbedPageJob.perform_later(page_id: @page.id)
        Result.ok(@page)
      end
    end
  end
end
