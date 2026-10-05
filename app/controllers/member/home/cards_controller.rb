# frozen_string_literal: true

module Member
  module Home
    # I modi per NON decidere adesso (CYRA-657): saltare, rimandare a domani, tornare indietro.
    #
    # Nessuna di queste azioni decide niente — non toccano il record, non avvisano nessuno, non
    # cambiano lo stato della lavorazione. Chi ha chiesto quella cosa continua a vederla in attesa.
    # Le decisioni vere stanno tutte dietro un'unica porta, `ApprovalsController#decide` (CYRA-630),
    # e qui non se ne apre una seconda.
    #
    # Ogni azione risolve la chiave con `Home::Approvals::Detail` PRIMA di scrivere: è l'unico posto
    # che sa se questo account quella card può vederla. Senza quel passaggio una chiave inventata
    # basterebbe a scrivere una riga su una card di un'altra organizzazione (anti-BOLA → 404, mai
    # 403, come già fa ActionsController).
    class CardsController < Member::BaseController
      permission_not_required "Rimanda o salta una card della propria home: non decide niente e la card si risolve " \
                              "solo se questo account la vede."

      include HomeSession

      # «Fammi vedere il resto»: la card scende di lato per questa sessione e torna da sé domani,
      # o subito con «indietro». Non tocca il database: vedi HomeSession.
      def skip
        skip_card(resolved_key!)
        redirect_to root_path
      end

      # «Non oggi»: la card sparisce fino a domani mattina, anche da un altro computer.
      def defer
        key = resolved_key!
        result = ::Home::Deferrals::Defer.call(account: Current.account, organization: current_organization,
                                               card_key: key)
        return redirect_to(root_path, alert: result.error.message) if result.err?

        remember_last_card(key)
        redirect_to root_path, notice: t("member.home.cards.deferred")
      end

      # «Torna indietro»: riprende l'ultima messa da parte. Non annulla una decisione già presa —
      # quello non si può fare, e il testo del pulsante non lo promette.
      def back
        resumed = unskip_last_card
        return redirect_to(root_path, alert: t("member.home.cards.nothing_back")) if resumed.blank?

        redirect_to root_path
      end

      private

      # La chiave, ma solo se questo account vede davvero quella card. Un 404 e non un 403: chi non
      # la vede non deve nemmeno sapere che esiste.
      def resolved_key!
        card = ::Home::Approvals::Detail.call(
          account: Current.account, organization: current_organization,
          visible_projects: visible.projects, visible_tickets: visible.tickets,
          key: params[:item]
        )
        raise ActiveRecord::RecordNotFound if card.nil?

        card.key
      end
    end
  end
end
