# frozen_string_literal: true

module Member
  module SharedSecretAssets
    class DelegationsController < Member::BaseController
      before_action -> { require_permission!("shared_secret_files.manage") }

      def create
        asset = Current.organization.secret_assets.where(project_id: nil).find(params[:shared_secret_asset_id])
        project = visible.projects.find(params[:project_id])
        delegation = asset.delegations.create!(project:, created_by: Current.account)
        ::Secrets::Assets::RecordEvent.call(action: "delegated", asset:, actor: Current.account,
                                             metadata: { project_id: project.id })
        redirect_to member_shared_secret_assets_path, notice: t("member.secret_assets.delegated")
      end

      def destroy
        asset = Current.organization.secret_assets.where(project_id: nil).find(params[:shared_secret_asset_id])
        delegation = asset.delegations.find(params[:id])
        project_id = delegation.project_id
        delegation.destroy!
        ::Secrets::Assets::RecordEvent.call(action: "undelegated", asset:, actor: Current.account,
                                             metadata: { project_id: })
        redirect_to member_shared_secret_assets_path, notice: t("member.secret_assets.undelegated")
      end
    end
  end
end
