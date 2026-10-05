# frozen_string_literal: true

module Cli
  module V1
    module Projects
      class SecretAssetsController < Cli::V1::BaseController
        before_action :set_project!

        def index
          return unless require_read

          scope = visible_assets.includes(:environment, :versions).ordered
          # Attore con restrizione env: la lista non mostra nemmeno gli asset degli env vietati.
          scope = scope.where(environment_id: allowed_environment_ids) if secret_access.restricted?
          records, meta = paginate(scope)
          render_ok(SecretAssetSerializer.new(records), meta:)
        end

        def create
          return unless require_manage

          environment = resolve_environment
          return if performed?
          return unless enforce_environment_code!(environment&.code, environment:, name: params[:name].to_s.strip)

          asset = @project.secret_assets.find_or_initialize_by(name: params[:name].to_s.strip,
                                                                environment_id: environment&.id)
          asset.assign_attributes(organization: @project.organization, description: params[:description],
                                  asset_type: inferred_type, created_by: Current.account)
          result = ::Secrets::Assets::Upload.call(asset:, uploaded_file: params[:file], actor: Current.account)
          return render_created(SecretAssetSerializer.new(asset.reload)) if result.ok?

          render_error(result.error.code, result.error.message, status: result.error.status, details: result.error.details)
        end

        def download
          return unless require_read

          asset = visible_assets.find(params[:id])
          return unless enforce_environment!(asset)

          version = params[:version].present? ? asset.versions.find_by!(number: params[:version]) : asset.current_version
          result = ::Secrets::Assets::Download.call(version:, actor: Current.account)
          return render_error(result.error.code, result.error.message, status: result.error.status) if result.err?

          # NB: niente clear() sul plaintext — ActionDispatch tiene per riferimento la stringa passata a send_data,
          # azzerarla la svuoterebbe PRIMA della serializzazione, restituendo un file vuoto (CYRA-134). Il GC la reclama a fine richiesta.
          send_data result.value, filename: version.original_filename, type: version.content_type, disposition: "attachment"
        end

        def versions
          return unless require_read

          asset = visible_assets.find(params[:id])
          return unless enforce_environment!(asset)

          render_ok(asset.versions.order(number: :desc).map { |v| version_json(v) })
        end

        def rollback
          return unless require_manage

          asset = project_assets.find(params[:id])
          return unless enforce_environment!(asset)

          source = asset.versions.find_by!(number: params.require(:version))
          result = ::Secrets::Assets::Rollback.call(source:, actor: Current.account)
          return render_error(result.error.code, result.error.message, status: result.error.status) if result.err?

          render_ok(SecretAssetSerializer.new(asset.reload))
        end

        def destroy
          return unless require_manage

          asset = project_assets.find(params[:id])
          return unless enforce_environment!(asset)

          asset.update!(archived_at: Time.current)
          ::Secrets::Assets::RecordEvent.call(action: "archived", asset:, actor: Current.account)
          render_no_content
        end

        def purge
          return unless require_owner!

          asset = project_assets.find(params[:id])
          return unless enforce_environment!(asset)
          return render_error("R422-SECRETFILE-007", "Archiviare l'asset prima del purge", status: :unprocessable_content) unless asset.archived?
          ::Secrets::Assets::RecordEvent.call(action: "purged", asset:, actor: Current.account,
                                               metadata: { name: asset.name, versions: asset.versions.count })
          versions = asset.versions.load
          ActiveRecord::Associations::Preloader.new(records: versions, associations: { ciphertext_attachment: :blob }).call
          asset.destroy!
          render_no_content
        end

        private

        def project_assets = @project.secret_assets
        def delegated_assets = ::Secrets::Asset.joins(:delegations).where(secrets_asset_delegations: { project_id: @project.id })
        def visible_assets = ::Secrets::Asset.where(id: project_assets.select(:id)).or(::Secrets::Asset.where(id: delegated_assets.select(:id)))
        def inferred_type = ::Secrets::Assets::Upload::EXTENSIONS.fetch(File.extname(params[:file]&.original_filename.to_s).downcase, "p8")

        def resolve_environment
          return nil if params[:environment].blank?
          env = @project.environments.find_by(id: params[:environment]) || @project.environments.find_by(code: params[:environment].to_s.downcase)
          return env if env
          render_error("R422-SECRETFILE-006", "Environment non dichiarato dal progetto", status: :unprocessable_content)
          nil
        end

        def require_read
          return true if authorization.can?("secret_files.read", scope: @project) || authorization.can?("secret_files.manage", scope: @project)
          render_error("R403-CLIAUTH-002", "Permesso negato", status: :forbidden)
          false
        end

        def require_manage = require_permission!("secret_files.manage", scope: @project)

        # Restrizione ambiente dell'attore (CYRA-268): l'account può essere confinato a certi
        # environment. Vale per OGNI ramo che tocca un file-segreto, non solo per le variabili: un asset
        # di un environment non consentito — o senza environment, quando la restrizione è attiva — è
        # negato con R403 (fail-closed), come già per i valori (R403-SECRET-001).
        # Da CYRA-78 la decisione arriva da Secrets::EnvironmentAccess (policy condivisa col canale web),
        # quindi vale anche l'override per-progetto. Da CYRA-666 il tentativo lascia un evento "denied"
        # anche qui: prima l'audit dei file non lo registrava, quindi un tentativo di scaricare una chiave
        # privata di un ambiente vietato non compariva da nessuna parte. Il canale sta nei metadata,
        # com'e' per i valori: una lettura dal terminale e una dal browser non pesano uguale.
        def enforce_environment!(asset) = enforce_environment_code!(asset.environment&.code, asset:)

        def enforce_environment_code!(code, asset: nil, environment: nil, name: nil)
          return true if secret_access.allowed?(code)

          ::Secrets::Assets::RecordEvent.call(action: "denied", asset:, actor: Current.account,
                                              project: @project, environment: environment || asset&.environment,
                                              organization: @project.organization,
                                              metadata: { channel: "cli", name: name.presence || asset&.name }.compact)
          render_error("R403-SECRETFILE-001", "environment non consentito per questo account", status: :forbidden)
          false
        end

        def secret_access
          @secret_access ||= ::Secrets::EnvironmentAccess.new(account: Current.account, project: @project)
        end

        # Gli asset visibili includono i DELEGATI da altri progetti dell'org: il filtro sugli id parte
        # quindi dagli environment dell'organizzazione, non da quelli dichiarati da questo progetto.
        def allowed_environment_ids
          ::Types::Environment.where(organization_id: Current.organization&.id,
                                     code: secret_access.restriction_codes).ids
        end

        def version_json(v) = { id: v.id, number: v.number, filename: v.original_filename, content_type: v.content_type,
                                byte_size: v.byte_size, fingerprint: v.fingerprint, created_at: v.created_at }
      end
    end
  end
end
