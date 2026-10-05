# frozen_string_literal: true

module Cli
  module V1
    module Artifacts
      class NativeSymbolsController < Cli::V1::BaseController
        include OtlpReadBudget
        before_action :set_project!
        before_action -> { require_permission!("artifacts.manage", scope: @project) }, only: %i[create destroy]
        confirmation_not_required "Uploading an immutable artifact does not overwrite existing data", only: :create
        around_action :reserve_upload_slot, only: :create

        rescue_from ::Artifacts::Rejected do |error|
          status = error.message == "request_too_large" ? :content_too_large : :unprocessable_content
          render_error(status == :content_too_large ? "R413-ARTIFACT-001" : "R422-ARTIFACT-001", error.message, status: status)
        end
        rescue_from ::Artifacts::Conflict do |error|
          render_error("R409-ARTIFACT-001", error.message, status: :conflict)
        end
        rescue_from ::Artifacts::Unavailable do
          render_error("R503-ARTIFACT-001", "Artifact storage is temporarily unavailable", status: :service_unavailable)
        end

        def index
          scope = @project.native_symbol_artifacts.order(created_at: :desc, id: :desc)
          scope = scope.where(debug_id: ::Artifacts::NativeSymbols::Identity.debug_id(params[:debug_id])) if params[:debug_id].present?
          records, meta = paginate_bounded(scope)
          preload(records)
          render_bounded(NativeSymbolArtifactSerializer.new(records), meta: meta)
        end

        def show
          artifact = bounded_record(@project.native_symbol_artifacts.where(id: params[:id]))
          preload([ artifact ])
          render_bounded(NativeSymbolArtifactSerializer.new(artifact))
        end

        def create
          raise ::Artifacts::Rejected, "unsupported_content_encoding" if request.headers["Content-Encoding"].present? && request.headers["Content-Encoding"] != "identity"
          bytes = request.body.read(::Artifacts::NativeSymbols::Processor::MAX_REQUEST + 1).to_s
          raise ::Artifacts::Rejected, "request_too_large" if bytes.bytesize > ::Artifacts::NativeSymbols::Processor::MAX_REQUEST
          value = JSON.parse(bytes, max_nesting: 32)
          raise ::Artifacts::Rejected, "invalid_upload" unless value.is_a?(Hash)
          outcome = ::Artifacts::NativeSymbols::Upload.call(project: @project, account: Current.account, metadata: value, object_base64: value["object_base64"])
          render json: { data: NativeSymbolArtifactSerializer.new(outcome.artifact).as_json }, status: outcome.duplicate ? :ok : :created
        rescue JSON::ParserError
          raise ::Artifacts::Rejected, "invalid_json"
        end

        def destroy
          @project.with_lock { @project.native_symbol_artifacts.find(params[:id]).destroy! }
          ::Artifacts::PruneJob.perform_later
          render_no_content
        end

        private

        def preload(records)
          ActiveRecord::Associations::Preloader.new(records: records, associations: :blob).call
        end

        def reserve_upload_slot
          reserved = false
          begin
            ::Artifacts::UPLOAD_SLOTS.push(true, true)
            reserved = true
          rescue ThreadError
            response.set_header("Retry-After", "1")
            raise ::Artifacts::Unavailable
          end
          yield
        ensure
          ::Artifacts::UPLOAD_SLOTS.pop if reserved
        end
      end
    end
  end
end
