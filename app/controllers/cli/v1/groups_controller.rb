# frozen_string_literal: true

module Cli
  module V1
    # Gruppi (macro-progetti) dell'organizzazione del token. Letture gated da `project_groups.view`
    # (chi gestisce con `project_groups.manage` vede sempre) e l'index è scopato ai gruppi VISIBILI
    # (visible_groups) — specchio del canale Member: un token a visibilità ristretta NON enumera più
    # tutti i gruppi dell'org. create/update/destroy gated da `project_groups.manage` (org-level).
    # Scoping org via `org_groups.find` (show/update/destroy) → un id di un'altra org dà R404 (anti-BOLA).
    class GroupsController < Cli::V1::BaseController
      before_action :require_groups_view, only: %i[index show]
      before_action :set_group, only: %i[show update destroy]
      before_action :require_groups_management, only: %i[create update destroy]

      def index
        records, meta = paginate(visible_groups.ordered)
        render_ok(GroupSerializer.new(records), meta: meta)
      end

      def show
        render_ok(GroupSerializer.new(@group))
      end

      def create
        group = org_groups.new(group_params)
        group.created_by = Current.account
        if group.save
          render_created(GroupSerializer.new(group))
        else
          render_group_error(group)
        end
      end

      def update
        if @group.update(group_params)
          render_ok(GroupSerializer.new(@group))
        else
          render_group_error(@group)
        end
      end

      def destroy
        ::Projects::Groups::Destroy.call(group: @group)
        render_no_content
      end

      private

      def set_group
        @group = org_groups.find(params[:id])
      end

      def org_groups
        Current.organization.groups
      end

      # icon_image binario resta web-only.
      def group_params
        params.permit(:name, :color, :icon)
      end

      def render_group_error(group)
        render_error("R422-GROUP-001", group.errors.full_messages.to_sentence,
                     status: :unprocessable_content, details: group.errors.to_hash)
      end

      # Lettura (index/show): gata da project_groups.view; chi gestisce (project_groups.manage) vede sempre.
      def require_groups_view
        require_permission!("project_groups.view") unless authorization.can?("project_groups.manage")
      end

      def require_groups_management
        require_permission!("project_groups.manage")
      end
    end
  end
end
