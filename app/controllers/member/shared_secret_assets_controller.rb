# frozen_string_literal: true

module Member
  class SharedSecretAssetsController < Member::BaseController
    before_action :require_manage

    def index
      @assets = Current.organization.secret_assets.where(project_id: nil).includes(:environment, :versions, delegations: :project).active.ordered
      @projects = visible.projects.order(:name)
    end

    def new
      @asset = Current.organization.secret_assets.new(project_id: nil)
      @environments = Current.organization.environments.active.ordered
    end

    def create
      environment = params[:environment_id].present? ? Current.organization.environments.find(params[:environment_id]) : nil
      @asset = Current.organization.secret_assets.find_or_initialize_by(project_id: nil, environment:, name: params[:name].to_s.strip)
      @asset.assign_attributes(asset_type: inferred_type, description: params[:description], created_by: Current.account)
      result = ::Secrets::Assets::Upload.call(asset: @asset, uploaded_file: params[:file], actor: Current.account)
      if result.ok?
        redirect_to member_shared_secret_assets_path, notice: t("member.secret_assets.saved"), status: :see_other
      else
        @environments = Current.organization.environments.active.ordered
        flash.now[:alert] = result.error.message
        render :new, status: :unprocessable_content
      end
    end

    def download
      asset = Current.organization.secret_assets.where(project_id: nil).find(params[:id])
      version = asset.current_version
      result = ::Secrets::Assets::Download.call(version:, actor: Current.account)
      return redirect_to member_shared_secret_assets_path, alert: result.error.message if result.err?
      # NB: niente clear() sul plaintext — ActionDispatch tiene per riferimento la stringa passata a send_data,
      # azzerarla la svuoterebbe PRIMA della serializzazione, restituendo un file vuoto (CYRA-134). Il GC la reclama a fine richiesta.
      send_data result.value, filename: version.original_filename, type: version.content_type, disposition: "attachment"
    end

    def destroy
      asset = shared_assets.find(params[:id])
      asset.update!(archived_at: Time.current)
      ::Secrets::Assets::RecordEvent.call(action: "archived", asset:, actor: Current.account)
      redirect_to member_shared_secret_assets_path, notice: t("member.secret_assets.archived")
    end

    # Storico versioni (parita con project/personal): sola lettura, ordinato dal piu recente.
    def versions
      @asset = shared_assets.find(params[:id])
      @versions = @asset.versions.order(number: :desc)
    end

    # Rollback: ricarica una versione precedente come nuova versione (pattern ProjectSecretAssets#rollback).
    def rollback
      asset = shared_assets.find(params[:id])
      source = asset.versions.find_by!(number: params.require(:version))
      result = ::Secrets::Assets::Rollback.call(source:, actor: Current.account)
      return redirect_to versions_member_shared_secret_asset_path(asset), alert: result.error.message if result.err?

      redirect_to versions_member_shared_secret_asset_path(asset), notice: t("member.secret_assets.rolled_back")
    end

    private

    def shared_assets = Current.organization.secret_assets.where(project_id: nil)
    def inferred_type = ::Secrets::Assets::Upload::EXTENSIONS.fetch(File.extname(params[:file]&.original_filename.to_s).downcase, "p8")
    def require_manage = require_permission!("shared_secret_files.manage")
  end
end
