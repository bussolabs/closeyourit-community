# frozen_string_literal: true

module Cli
  module V1
    module Members
      # Ruolo della membership come sub-resource singleton: PUT = cambia ruolo (member <-> admin).
      # Gate `members.manage`. Logica in Connections::ChangeRole (vieta di declassare l'ultimo owner,
      # R422-MEMBER-*), condivisa col canale Member (`rules/backend-channels.md`): qui solo auth/gate/serializzazione.
      class RolesController < Cli::V1::BaseController
        before_action :set_membership
        before_action -> { require_permission!("members.manage") }

        def update
          result = Connections::ChangeRole.call(membership: @membership, role: params[:role])
          if result.ok?
            render_ok(MemberSerializer.new(@membership.reload))
          else
            render_error(result.error.code, result.error.message,
                         status: result.error.status, details: result.error.details)
          end
        end

        private

        # Anti-BOLA: la membership si risolve dentro l'org corrente → un id di altra org → R404 (prima del gate).
        def set_membership
          @membership = Current.organization.memberships.find(params[:member_id])
        end
      end
    end
  end
end
