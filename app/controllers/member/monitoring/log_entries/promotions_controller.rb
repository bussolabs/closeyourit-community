# frozen_string_literal: true

module Member
  module Monitoring
    module LogEntries
      # CYRA-347 — apre un ticket già compilato dal messaggio, come il pulsante che esiste da sempre
      # sulla scheda di un rallentamento. Stesso gate del collegamento manuale (`logs.link`): quello
      # che nasce qui È un collegamento log↔ticket, con in più il ticket.
      #
      # Anti-BOLA via visible.logs: un messaggio che non vedi non esiste, non è vietato.
      class PromotionsController < Member::BaseController
        before_action :set_entry
        before_action -> { require_permission!("logs.link", scope: @entry.project) }

        def create
          result = Logs::PromoteToTicket.call(entry: @entry, reporter: Current.account,
                                              true_actor: Current.true_account)
          redirect_to member_monitoring_log_entry_path(@entry), **outcome(result)
        end

        private

        def set_entry
          @entry = visible.logs.find(params[:log_entry_id])
        end

        # Riusare un ticket già aperto da un messaggio identico non è un fallimento: è la risposta
        # giusta, e va detta — altrimenti sembra che il pulsante non abbia fatto niente.
        def outcome(result)
          return { alert: t("member.monitoring.logs.promote_failed") } unless result.ok?

          key = result.value.reused ? "promote_reused" : "promoted"
          { notice: t("member.monitoring.logs.#{key}", code: result.value.ticket.code) }
        end
      end
    end
  end
end
