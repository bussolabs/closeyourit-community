# frozen_string_literal: true

module Cli
  module V1
    module Members
      # Accessi & permessi della membership come sub-resource singleton (PUT). Gate `members.manage`.
      # Parità col canale Member (Member::MembersController#update_access): oltre allo scope gruppi/progetti
      # (Connections::SetMemberAccess) accetta i ruoli DIRETTI (`role_ids[]` → Authorization::SetAccountRoles)
      # e gli override personali (`overrides{key=>inherit|allow|deny}` → Authorization::SetAccountPermissions).
      # Ogni sotto-operazione è FULL-REPLACE ma applicata SOLO se il suo parametro è presente nel request:
      # un client che manda solo group_ids/project_ids NON azzera ruoli/override (no footgun sui client
      # esistenti). group_ids/project_ids restano full-replace come prima. Logica nei service condivisi
      # (`rules/backend-channels.md`, idempotenti, anti-BOLA sull'org): qui solo auth/gate/serializzazione.
      class AccessesController < Cli::V1::BaseController
        before_action :set_membership
        before_action -> { require_permission!("members.manage") }

        def update
          result = apply_access(@membership.account)
          if result.err?
            render_result_error(result)
          else
            render_ok(MemberSerializer.new(@membership.reload))
          end
        end

        private

        # CYRA-243: ruoli/override/scope ATOMICI (parità col canale Member#update_access). Ruoli e override
        # applicati solo se il parametro è presente (no footgun sui client parziali), scope per ULTIMO e
        # sempre full-replace. Ogni guard (R403-ACCESS-001) gira PRIMA della propria transazione: al primo
        # err annullo tutto (rollback) e nulla resta salvato — prima lo scope committava per primo e i
        # progetti restavano assegnati anche quando i ruoli venivano rifiutati.
        def apply_access(account)
          result = nil
          ActiveRecord::Base.transaction do
            if params.key?(:role_ids)
              result = apply_roles(account)
              raise ActiveRecord::Rollback if result.err?
            end
            if params.key?(:overrides)
              result = apply_overrides(account)
              raise ActiveRecord::Rollback if result.err?
            end
            result = Connections::SetMemberAccess.call(
              organization: Current.organization, account: account,
              group_ids: params[:group_ids], project_ids: params[:project_ids], actor: Current.account
            )
            raise ActiveRecord::Rollback if result.err?
          end
          result
        end

        # Propaga un Result::err col suo codice/status/details (mai silenziato).
        def render_result_error(result)
          render_error(result.error.code, result.error.message,
                       status: result.error.status, details: result.error.details)
        end

        # Ruoli diretti (full-replace dell'insieme dell'org). true_actor nil in CLI (nessuna impersonation).
        def apply_roles(account)
          Authorization::SetAccountRoles.call(
            organization: Current.organization, account: account, role_ids: params[:role_ids],
            actor: Current.account, true_actor: Current.true_account
          )
        end

        # Override personali allow/deny (full-replace). params[:overrides] = { key => "inherit|allow|deny" }.
        def apply_overrides(account)
          allow_keys, deny_keys = split_overrides(params[:overrides])
          Authorization::SetAccountPermissions.call(
            organization: Current.organization, account: account,
            allow_keys: allow_keys, deny_keys: deny_keys,
            actor: Current.account, true_actor: Current.true_account
          )
        end

        # { key => "inherit|allow|deny" } → [allow_keys, deny_keys] (specchio di Member::MembersController).
        def split_overrides(overrides)
          allow = []
          deny = []
          overrides&.each_pair do |key, value|
            allow << key if value == "allow"
            deny << key if value == "deny"
          end
          [ allow, deny ]
        end

        # Anti-BOLA: membership dentro l'org corrente → id di altra org → R404 (prima del gate).
        def set_membership
          @membership = Current.organization.memberships.find(params[:member_id])
        end
      end
    end
  end
end
