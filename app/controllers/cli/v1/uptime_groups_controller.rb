# frozen_string_literal: true

module Cli
  module V1
    # Gruppi di monitor uptime (contenitori ORG-LEVEL, distinti da Projects::Group / `cli/v1/groups`).
    # Lettura (index/show) gated `uptime_groups.view` (chi gestisce con `uptime_groups.manage` vede
    # sempre); create/update/destroy gated `uptime_groups.manage`. Visibilità = PERMESSO, non scope:
    # superato il gate si opera su Current.organization.uptime_groups (id di altra org → R404, anti-BOLA).
    # Publish/unpublish della status page pubblica in `uptime_groups/:id/publication`. Specchio di
    # Member::Monitoring::UptimeGroupsController.
    class UptimeGroupsController < Cli::V1::BaseController
      before_action :require_uptime_groups_view, only: %i[index show]
      before_action :set_group, only: %i[show update destroy]
      before_action :require_uptime_groups_management, only: %i[create update destroy]

      def index
        records, meta = paginate(org_uptime_groups.ordered)
        render_ok(UptimeGroupSerializer.new(records), meta: meta)
      end

      def show
        render_ok(UptimeGroupSerializer.new(@group))
      end

      def create
        group = org_uptime_groups.new(group_params)
        group.created_by = Current.account
        if group.save
          render_created(UptimeGroupSerializer.new(group))
        else
          render_group_error(group)
        end
      end

      def update
        if @group.update(group_params)
          render_ok(UptimeGroupSerializer.new(@group))
        else
          render_group_error(@group)
        end
      end

      def destroy
        @group.destroy
        render_no_content
      end

      private

      def org_uptime_groups
        Current.organization.uptime_groups
      end

      def set_group
        @group = org_uptime_groups.find(params[:id])
      end

      # icon_image binario resta web-only; slug è auto-derivato dal model.
      def group_params
        params.permit(:name, :color, :icon, :description)
      end

      def render_group_error(group)
        render_error("R422-UPTIMEGROUP-001", group.errors.full_messages.to_sentence,
                     status: :unprocessable_content, details: group.errors.to_hash)
      end

      # Lettura (index/show): gata da uptime_groups.view; chi gestisce (uptime_groups.manage) vede sempre.
      def require_uptime_groups_view
        require_permission!("uptime_groups.view") unless authorization.can?("uptime_groups.manage")
      end

      def require_uptime_groups_management
        require_permission!("uptime_groups.manage")
      end
    end
  end
end
