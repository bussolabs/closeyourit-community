# frozen_string_literal: true

module Cli
  module V1
    module UptimeGroups
      # Status page pubblica (opt-in) di un gruppo di monitor uptime come sub-resource SINGLETON:
      # PUT = pubblica, DELETE = ritira. Gate `uptime_groups.manage`. update_column (non update!): il flag
      # pubblico è una preferenza indipendente, non bloccata da validazioni estranee del gruppo — specchio
      # di Member::Monitoring::UptimeGroupsController#publish/#unpublish. Anti-BOLA: gruppo dell'org (id di
      # altra org → R404).
      class PublicationsController < Cli::V1::BaseController
        before_action :set_group
        before_action -> { require_permission!("uptime_groups.manage") }

        def update
          @group.update_column(:public_status_enabled, true)
          render_ok(UptimeGroupSerializer.new(@group))
        end

        def destroy
          @group.update_column(:public_status_enabled, false)
          render_ok(UptimeGroupSerializer.new(@group))
        end

        private

        def set_group
          @group = Current.organization.uptime_groups.find(params[:uptime_group_id])
        end
      end
    end
  end
end
