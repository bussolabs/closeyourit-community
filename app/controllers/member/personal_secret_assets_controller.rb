# frozen_string_literal: true

module Member
  # File segreti PERSONALI (CYRA-133): gemello per-utente di Member::ProjectSecretAssetsController.
  # Ownership — nessun RBAC, nessun environment, nessuna delega: lo scope è
  # Secrets::Personal::Asset.for(account, org) e il find dentro quello scope è anti-BOLA 404. Controller
  # FLAT (come PersonalSecretsController) per non ombreggiare ::Secrets. Download SEMPRE come attachment
  # (file arbitrari cifrati, mai render inline → niente stored-XSS/exec).
  class PersonalSecretAssetsController < Member::BaseController
    permission_not_required "Cassaforte personale: i file sono dell'utente, lo scope per account è anche il confine."

    RECENT_EVENTS = 15

    def index
      @assets = owned_assets.includes(:versions).active.ordered
      @events = ::Secrets::Personal::AssetEvent
                .for(account: Current.account, organization: Current.organization)
                .recent.limit(RECENT_EVENTS)
    end

    def new
      @asset = owned_assets.new
    end

    def create
      # find_or_initialize su TUTTI i propri (anche archiviati): ricaricare un nome archiviato riattiva
      # il file (archived_at: nil), altrimenti l'upload "riuscirebbe" ma il file resterebbe invisibile e
      # il nome irriproducibile (unique index su [account, organization, name]).
      @asset = owned_assets.find_or_initialize_by(name: params[:name].to_s.strip)
      @asset.assign_attributes(description: params[:description], archived_at: nil)
      result = ::Secrets::Personal::Assets::Upload.call(asset: @asset, uploaded_file: params[:file])
      if result.ok?
        redirect_to member_personal_secret_assets_path, notice: t("member.personal_secret_assets.saved"), status: :see_other
      else
        flash.now[:alert] = result.error.message
        render :new, status: :unprocessable_content
      end
    end

    def download
      asset = owned_assets.find(params[:id])
      version = resolve_version(asset)
      result = ::Secrets::Personal::Assets::Download.call(version:)
      return redirect_to member_personal_secret_assets_path, alert: result.error.message if result.err?

      # NB: niente clear() sul plaintext qui — ActionDispatch tiene per riferimento la stringa passata a
      # send_data, azzerarla la svuoterebbe prima della serializzazione. Il GC la reclama a fine richiesta.
      send_data result.value, filename: version.original_filename, type: version.content_type, disposition: "attachment"
    end

    def versions
      @asset = owned_assets.find(params[:id])
      @versions = @asset.versions.order(number: :desc)
    end

    def rollback
      asset = owned_assets.find(params[:id])
      source = asset.versions.find_by!(number: params.require(:version))
      result = ::Secrets::Personal::Assets::Rollback.call(source:)
      return redirect_to versions_member_personal_secret_asset_path(asset), alert: result.error.message if result.err?

      redirect_to versions_member_personal_secret_asset_path(asset), notice: t("member.personal_secret_assets.rolled_back")
    end

    def destroy
      asset = owned_assets.find(params[:id])
      asset.update!(archived_at: Time.current)
      ::Secrets::Personal::Assets::RecordEvent.call(action: "archived", asset:)
      redirect_to member_personal_secret_assets_path, notice: t("member.personal_secret_assets.archived")
    end

    def purge
      asset = owned_assets.find(params[:id])
      raise ActiveRecord::RecordInvalid, asset unless asset.archived?

      ::Secrets::Personal::Assets::RecordEvent.call(action: "purged", asset:, metadata: { versions: asset.versions.count })
      asset.destroy!
      redirect_to member_personal_secret_assets_path, notice: t("member.personal_secret_assets.purged")
    end

    private

    def owned_assets
      ::Secrets::Personal::Asset.for(account: Current.account, organization: Current.organization)
    end

    def resolve_version(asset)
      params[:version].present? ? asset.versions.find_by!(number: params[:version]) : asset.current_version
    end
  end
end
