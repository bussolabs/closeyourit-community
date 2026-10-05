# frozen_string_literal: true

module Knowledge
  module Pages
    # Scarta una proposta in revisione (CYRA-298). La pagina NON viene cancellata: resta come
    # rejected, fuori da ricerca, RAG, correlate e liste.
    #
    # Perché tenerla: chi propone cerca i duplicati prima di scrivere, e fra i duplicati deve
    # trovare anche ciò che è già stato bocciato. Cancellandola, domani si riproporrebbe la stessa
    # nota — e la revisione diventerebbe un lavoro ricorrente invece di una decisione presa una volta.
    class Reject < ApplicationService
      include ReviewGuards

      def initialize(page:, actor:)
        @page = page
        @actor = actor
      end

      def call
        # Come in Approve, il guard umano è il PRIMO (CYRA-642): scartare toglie una proposta dalla
        # coda per sempre, e quella coda esiste perché a leggerla sia qualcuno.
        return machine_decision unless human_actor?
        return wrong_status(:not_in_review) unless @page.status_in_review?
        return forbidden unless manageable?

        @page.update!(status: :rejected, reviewed_by: @actor, reviewed_at: Time.current)
        Result.ok(@page)
      end
    end
  end
end
