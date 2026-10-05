# frozen_string_literal: true

module Member
  class ProjectSecretAssetsController < Member::BaseController
    include Member::SecretEnvironmentBoundary

    before_action :set_project
    before_action :require_read, only: %i[index download versions]
    before_action :require_manage, only: %i[new create destroy rollback]
    before_action :require_owner, only: :purge

    def index
      scope = visible_assets.includes(:environment, :versions).active.ordered
      # CYRA-666 — l'attore confinato non vede nemmeno che esistono: l'elenco si filtra come sul canale
      # CLI, sugli ambienti dell'ORGANIZZAZIONE (i file delegati arrivano da altri progetti).
      scope = scope.where(environment_id: allowed_environment_ids) if secret_access.restricted?
      @assets = scope
      @stats = @project.ticket_tally
    end

    def new
      @asset = @project.secret_assets.new
      @environments = @project.environments.active.ordered
    end

    def create
      environment = params[:environment_id].present? ? @project.environments.find(params[:environment_id]) : nil
      return deny_environment(environment:, name: params[:name].to_s.strip) unless environment_allowed?(environment)

      @asset = @project.secret_assets.find_or_initialize_by(name: params[:name].to_s.strip, environment:)
      @asset.assign_attributes(organization: @project.organization, description: params[:description],
                               asset_type: inferred_type, created_by: Current.account)
      result = ::Secrets::Assets::Upload.call(asset: @asset, uploaded_file: params[:file], actor: Current.account)
      if result.ok?
        redirect_to member_project_secret_assets_path(@project), notice: t("member.secret_assets.saved"), status: :see_other
      else
        @environments = @project.environments.active.ordered
        flash.now[:alert] = result.error.message
        render :new, status: :unprocessable_content
      end
    end

    def download
      asset = visible_assets.find(params[:id])
      return deny_environment(asset:) unless environment_allowed?(asset.environment)

      version = params[:version].present? ? asset.versions.find_by!(number: params[:version]) : asset.current_version
      result = ::Secrets::Assets::Download.call(version:, actor: Current.account)
      return redirect_to member_project_secret_assets_path(@project), alert: result.error.message if result.err?

      # NB: niente clear() sul plaintext — ActionDispatch tiene per riferimento la stringa passata a send_data,
      # azzerarla la svuoterebbe PRIMA della serializzazione, restituendo un file vuoto (CYRA-134). Il GC la reclama a fine richiesta.
      send_data result.value, filename: version.original_filename, type: version.content_type, disposition: "attachment"
    end

    def versions
      @asset = visible_assets.find(params[:id])
      return deny_environment(asset: @asset) unless environment_allowed?(@asset.environment)

      @versions = @asset.versions.order(number: :desc)
      @stats = @project.ticket_tally
    end

    def rollback
      asset = @project.secret_assets.find(params[:id])
      return deny_environment(asset:) unless environment_allowed?(asset.environment)

      source = asset.versions.find_by!(number: params.require(:version))
      result = ::Secrets::Assets::Rollback.call(source:, actor: Current.account)
      if result.err?
        return redirect_to versions_member_project_secret_asset_path(@project, asset), alert: result.error.message
      end

      redirect_to versions_member_project_secret_asset_path(@project, asset), notice: t("member.secret_assets.rolled_back")
    end

    def destroy
      asset = @project.secret_assets.find(params[:id])
      return deny_environment(asset:) unless environment_allowed?(asset.environment)

      asset.update!(archived_at: Time.current)
      ::Secrets::Assets::RecordEvent.call(action: "archived", asset:, actor: Current.account)
      redirect_to member_project_secret_assets_path(@project), notice: t("member.secret_assets.archived")
    end

    def purge
      asset = @project.secret_assets.find(params[:id])
      return deny_environment(asset:) unless environment_allowed?(asset.environment)

      raise ActiveRecord::RecordInvalid, asset unless asset.archived?
      ::Secrets::Assets::RecordEvent.call(action: "purged", asset:, actor: Current.account,
                                           metadata: { name: asset.name, versions: asset.versions.count })
      asset.destroy!
      redirect_to member_project_secret_assets_path(@project), notice: t("member.secret_assets.purged")
    end

    private

    def set_project = @project = visible.projects.find(params[:project_id])
    def own_assets = @project.secret_assets
    def delegated_assets = ::Secrets::Asset.joins(:delegations).where(secrets_asset_delegations: { project_id: @project.id })
    def visible_assets = ::Secrets::Asset.where(id: own_assets.select(:id)).or(::Secrets::Asset.where(id: delegated_assets.select(:id)))
    def inferred_type = ::Secrets::Assets::Upload::EXTENSIONS.fetch(File.extname(params[:file]&.original_filename.to_s).downcase, "p8")
    def require_manage = require_permission!("secret_files.manage", scope: @project)

    def require_owner
      note_permission_check! # CYRA-727 — qui si decide, anche quando la risposta non passa da una chiave.
      membership = Current.organization.memberships.find_by(account: Current.account)
      return if Current.account&.god? || membership&.owner?
      redirect_to root_path, alert: t("member.forbidden")
    end

    def require_read
      return if can?("secret_files.read", scope: @project) || can?("secret_files.manage", scope: @project)
      redirect_to root_path, alert: t("member.forbidden")
    end

    # CYRA-666 — rifiuto del confine ambienti. Il tentativo finisce nell'audit PRIMA del rifiuto, come
    # gia' avviene sui valori: provare a scaricare una chiave privata di un ambiente vietato e' l'evento
    # che si vuole ritrovare, e finora sui file non lasciava traccia da nessuna parte. Sul caricamento
    # l'asset non esiste ancora, quindi il contesto (progetto, ambiente, nome tentato) viaggia a parte.
    # Il rimbalzo e' all'elenco e non alla home: l'attore il progetto lo vede, e' l'ambiente che non gli
    # spetta.
    def deny_environment(asset: nil, environment: nil, name: nil)
      ::Secrets::Assets::RecordEvent.call(action: "denied", asset:, actor: Current.account,
                                          project: @project, environment: environment || asset&.environment,
                                          organization: @project.organization,
                                          metadata: { channel: "web", name: name.presence || asset&.name }.compact)
      redirect_to member_project_secret_assets_path(@project), alert: t("member.secrets.environment_denied")
    end
  end
end
