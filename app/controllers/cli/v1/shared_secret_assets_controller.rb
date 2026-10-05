# frozen_string_literal: true

module Cli
  module V1
    # File segreti CONDIVISI org-level da terminale (`cyi shared files`). Gate RBAC unico
    # shared_secret_files.manage (org-level, dangerous); da CYRA-641 il ciclo di vita è quello dei file
    # di progetto — storico, ripristino, cancellazione definitiva riservata a owner/god — più le
    # deleghe a un progetto, che esistono solo qui.
    class SharedSecretAssetsController < Cli::V1::BaseController
      before_action -> { require_permission!("shared_secret_files.manage") }

      def index
        records, meta = paginate(assets.includes(:environment, :versions, :delegated_projects).ordered)
        render_ok(SecretAssetSerializer.new(records), meta:)
      end

      def create
        environment = resolve_environment
        return if performed?
        asset = assets.find_or_initialize_by(name: params[:name].to_s.strip, environment:)
        asset.assign_attributes(asset_type: inferred_type, description: params[:description], created_by: Current.account)
        result = ::Secrets::Assets::Upload.call(asset:, uploaded_file: params[:file], actor: Current.account)
        return render_created(SecretAssetSerializer.new(asset.reload)) if result.ok?
        render_error(result.error.code, result.error.message, status: result.error.status, details: result.error.details)
      end

      def download
        asset = assets.find(params[:id])
        version = params[:version].present? ? asset.versions.find_by!(number: params[:version]) : asset.current_version
        result = ::Secrets::Assets::Download.call(version:, actor: Current.account)
        return render_error(result.error.code, result.error.message, status: result.error.status) if result.err?
        # NB: niente clear() sul plaintext — ActionDispatch tiene per riferimento la stringa passata a send_data,
        # azzerarla la svuoterebbe PRIMA della serializzazione, restituendo un file vuoto (CYRA-134). Il GC la reclama a fine richiesta.
        send_data result.value, filename: version.original_filename, type: version.content_type, disposition: "attachment"
      end

      def versions
        asset = assets.find(params[:id])
        render_ok(asset.versions.order(number: :desc).map { |version| version_json(version) })
      end

      def rollback
        asset = assets.find(params[:id])
        source = asset.versions.find_by!(number: params.require(:version))
        result = ::Secrets::Assets::Rollback.call(source:, actor: Current.account)
        return render_error(result.error.code, result.error.message, status: result.error.status) if result.err?

        render_ok(SecretAssetSerializer.new(asset.reload))
      end

      def delegate
        asset = assets.find(params[:id])
        project = visible_projects.find(params.require(:project_id))
        delegation = asset.delegations.create!(project:, created_by: Current.account)
        ::Secrets::Assets::RecordEvent.call(action: "delegated", asset:, actor: Current.account,
                                             metadata: { project_id: project.id })
        render_created({ id: delegation.id, project_id: project.id })
      end

      def undelegate
        asset = assets.find(params[:id])
        delegation = asset.delegations.find_by!(project_id: params.require(:project_id))
        delegation.destroy!
        ::Secrets::Assets::RecordEvent.call(action: "undelegated", asset:, actor: Current.account,
                                             metadata: { project_id: params[:project_id] })
        render_no_content
      end

      def destroy
        asset = assets.find(params[:id])
        asset.update!(archived_at: Time.current)
        ::Secrets::Assets::RecordEvent.call(action: "archived", asset:, actor: Current.account)
        render_no_content
      end

      # Cancellazione definitiva: come per i file di progetto serve l'archiviazione prima e il solo
      # manage non basta — un file condiviso può essere delegato a più progetti, e distruggerne
      # ciphertext e storico è irreversibile per tutti quanti insieme.
      def purge
        return unless require_owner!

        asset = assets.find(params[:id])
        return render_error("R422-SECRETFILE-007", "Archiviare l'asset prima del purge", status: :unprocessable_content) unless asset.archived?

        ::Secrets::Assets::RecordEvent.call(action: "purged", asset:, actor: Current.account,
                                             metadata: { name: asset.name, versions: asset.versions.count })
        versions = asset.versions.load
        ActiveRecord::Associations::Preloader.new(records: versions, associations: { ciphertext_attachment: :blob }).call
        asset.destroy!
        render_no_content
      end

      private

      def assets = Current.organization.secret_assets.where(project_id: nil)
      def inferred_type = ::Secrets::Assets::Upload::EXTENSIONS.fetch(File.extname(params[:file]&.original_filename.to_s).downcase, "p8")

      def resolve_environment
        return nil if params[:environment].blank?
        env = Current.organization.environments.find_by(id: params[:environment]) || Current.organization.environments.find_by(code: params[:environment].to_s.downcase)
        return env if env
        render_error("R422-SECRETFILE-006", "Environment non appartenente all'organizzazione", status: :unprocessable_content)
        nil
      end

      def version_json(version)
        { id: version.id, number: version.number, filename: version.original_filename,
          content_type: version.content_type, byte_size: version.byte_size,
          fingerprint: version.fingerprint, created_at: version.created_at }
      end
    end
  end
end
