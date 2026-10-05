# frozen_string_literal: true

module Cli
  module V1
    module MetricGroups
      # Promozione a ticket come risorsa singleton: PUT promuove il gruppo-metrica (query/metodo lento).
      # Gate metrics.promote. Il service è idempotente (già promosso → R422-METRIC-001). Risponde col
      # ticket creato (come la creazione ticket del canale CLI). Mirror di ErrorGroups::PromotionsController.
      class PromotionsController < Cli::V1::BaseController
        before_action :set_project!
        before_action -> { require_permission!("metrics.promote", scope: @project) }

        def update
          group = @project.metric_groups.find(params[:metric_group_id])
          # true_actor = Current.account: la CLI è account-proxy senza impersonation (Current.true_account
          # è sempre nil qui) → l'audit deve registrare l'account, coerente col resto del canale CLI.
          result = Metrics::PromoteToTicket.call(
            group:, reporter: Current.account, true_actor: Current.account
          )
          return render_created(TicketSerializer.new(result.value)) if result.ok?

          render_error(result.error.code, result.error.message,
                       status: result.error.status, details: result.error.details)
        end
      end
    end
  end
end
