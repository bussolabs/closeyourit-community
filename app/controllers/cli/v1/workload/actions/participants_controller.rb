# frozen_string_literal: true

module Cli
  module V1
    module Workload
      module Actions
        # Partecipanti di una workload action via CLI: POST aggiunge un account (deve essere membro del
        # team della action, validato dal model → 422 se estraneo), DELETE lo rimuove per account_id
        # (idempotente). Team-scoped: action di un altro team → RecordNotFound → R404. Nessuna
        # permission key (auth = appartenenza al team).
        class ParticipantsController < Cli::V1::BaseController
          before_action :set_action

          def create
            participation = @action.participations.new(account_id: params[:account_id])
            if participation.save
              render_created(WorkloadActionSerializer.new(@action.reload))
            else
              render_error("R422-WORKLOAD-002", participation.errors.full_messages.to_sentence,
                           status: :unprocessable_content, details: participation.errors.to_hash)
            end
          end

          def destroy
            @action.participations.where(account_id: params[:id]).destroy_all
            render_no_content
          end

          private

          def set_action
            @action = ::Workload::Action.visible_to(account: Current.account, organization: Current.organization)
                                        .find(params[:action_id])
          end
        end
      end
    end
  end
end
