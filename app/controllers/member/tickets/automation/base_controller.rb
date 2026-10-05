# frozen_string_literal: true

module Member
  module Tickets
    module Automation
      # Base delle azioni sull'automazione (CYRA-219). Tutte fanno la stessa cosa in coda: riportare alla
      # SCHEDA da cui si è agito, non al dettaglio — chi approva un piano vuole rivedere i passi, non la
      # descrizione del ticket. Prima tornavano tutte a member_ticket_path, che con le schede è il dettaglio.
      class BaseController < Member::BaseController
        permission_not_required "Azioni sull'automazione di un ticket visibile: chi possa decidere lo stabilisce il " \
                                "service della lavorazione."

        private

        def redirect_to_automation(ticket, result, notice_key)
          redirect_to member_ticket_path(ticket, tab: "automation"),
                      result.ok? ? { notice: t(notice_key) } : { alert: result.error.message }
        end

        def workflow_for(ticket_id)
          visible.tickets.find(ticket_id).agent_workflow
        end
      end
    end
  end
end
