# frozen_string_literal: true

module Cli
  module V1
    # File segreti PERSONALI da terminale (`cyi personal files`). Ownership: nessuna permission
    # key, scope Secrets::Personal::Asset.for(account, org), find anti-BOLA 404. I metadati escono dalle
    # liste (MAI il ciphertext); il contenuto solo da download come attachment. :id = UUID oppure NAME.
    # Da CYRA-641 il ciclo di vita è quello dei file di progetto — storico, ripristino, purge — meno le
    # deleghe, che nel personale non esistono (non c'è nessun progetto a cui prestare un file proprio).
    class PersonalSecretAssetsController < Cli::V1::BaseController
      UUID_FORMAT = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

      # Elenca anche gli ARCHIVIATI (come il canale di progetto, e a differenza della pagina web che ha
      # la sua tab): il purge esige l'archiviazione prima, e da terminale un file invisibile è un file
      # che non si può più né confermare per nome né eliminare. Lo stato lo dice `archived_at`.
      def index
        records, meta = paginate(owned_assets.includes(:versions).ordered)
        render_ok(PersonalSecretAssetSerializer.new(records), meta:)
      end

      def create
        # Riattiva un file archiviato se se ne ricarica uno con lo stesso nome (vedi controller web).
        asset = owned_assets.find_or_initialize_by(name: params[:name].to_s.strip)
        asset.assign_attributes(description: params[:description], archived_at: nil)
        result = ::Secrets::Personal::Assets::Upload.call(asset:, uploaded_file: params[:file])
        return render_created(PersonalSecretAssetSerializer.new(asset)) if result.ok?

        render_error(result.error.code, result.error.message, status: result.error.status, details: result.error.details)
      end

      def download
        asset = find_asset!
        version = params[:version].present? ? asset.versions.find_by!(number: params[:version]) : asset.current_version
        result = ::Secrets::Personal::Assets::Download.call(version:)
        return render_error(result.error.code, result.error.message, status: result.error.status) if result.err?

        # NB: niente clear() sul plaintext (send_data lo tiene per riferimento) — vedi controller web.
        send_data result.value, filename: version.original_filename, type: version.content_type, disposition: "attachment"
      end

      def versions
        asset = find_asset!
        render_ok(asset.versions.order(number: :desc).map { |version| version_json(version) })
      end

      def rollback
        asset = find_asset!
        source = asset.versions.find_by!(number: params.require(:version))
        result = ::Secrets::Personal::Assets::Rollback.call(source:)
        return render_error(result.error.code, result.error.message, status: result.error.status) if result.err?

        render_ok(PersonalSecretAssetSerializer.new(asset.reload))
      end

      def destroy
        asset = find_asset!
        asset.update!(archived_at: Time.current)
        ::Secrets::Personal::Assets::RecordEvent.call(action: "archived", asset:)
        render_no_content
      end

      # Cancellazione definitiva: distrugge ciphertext e storico, quindi esige l'archiviazione prima
      # (stesso guardrail dei file di progetto). L'audit sopravvive: l'evento porta il nome nel metadata
      # e la FK va a NULL.
      def purge
        asset = find_asset!
        unless asset.archived?
          return render_error("R422-PERSONALSECRETFILE-007", "Archiviare il file prima della cancellazione definitiva",
                              status: :unprocessable_content)
        end

        ::Secrets::Personal::Assets::RecordEvent.call(action: "purged", asset:, metadata: { versions: asset.versions.count })
        versions = asset.versions.load
        ActiveRecord::Associations::Preloader.new(records: versions, associations: { ciphertext_attachment: :blob }).call
        asset.destroy!
        render_no_content
      end

      private

      def owned_assets
        ::Secrets::Personal::Asset.for(account: Current.account, organization: Current.organization)
      end

      # UUID → find per id nello scope; NAME → find_by! per nome. Not found → RecordNotFound → 404.
      def find_asset!
        ref = params[:id].to_s.strip
        return owned_assets.find(ref) if ref.match?(UUID_FORMAT)

        owned_assets.find_by!(name: ref)
      end

      def version_json(version)
        { id: version.id, number: version.number, filename: version.original_filename,
          content_type: version.content_type, byte_size: version.byte_size,
          fingerprint: version.fingerprint, created_at: version.created_at }
      end
    end
  end
end
