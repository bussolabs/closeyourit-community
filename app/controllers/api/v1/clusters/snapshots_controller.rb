# frozen_string_literal: true

module Api
  module V1
    module Clusters
      # Receives the full cluster state from closeyourit-kube every minute (cluster-snapshot/v1).
      # Synchronous: auth, size, minimal shape, idempotency, arrival time. The rest is IngestJob (CYAG-22).
      class SnapshotsController < Api::BaseController
        include ClusterAuthentication

        before_action :authenticate_cluster!

        GZIP_MAGIC = "\x1f\x8b".b
        LISTS = %w[nodes namespaces workloads events].freeze

        def create
          max = ::Clusters::Constants::MAX_PAYLOAD_BYTES
          return too_large if request.content_length.to_i > max

          payload = parse_payload(max)
          return too_large if payload == :too_large
          return invalid unless valid_shape?(payload)

          accept(Current.cluster, payload)
          render json: { data: { accepted: true, cluster_id: Current.cluster.id } }, status: :accepted
        end

        private

        # The arrival time is written here, synchronously: cluster health never waits for the ingest
        # lane. The same snapshot_id twice is accepted but ingested once.
        def accept(cluster, payload)
          duplicate = cluster.last_snapshot_id == payload["snapshot_id"]
          now = Time.current
          cluster.update_columns(last_snapshot_at: now, last_snapshot_id: payload["snapshot_id"], updated_at: now)
          ::Clusters::IngestJob.perform_later(cluster_id: cluster.id, payload:) unless duplicate
        end

        def valid_shape?(payload)
          payload.is_a?(Hash) && payload["snapshot_id"].is_a?(String) && payload["snapshot_id"].present? &&
            LISTS.all? { |key| payload[key].is_a?(Array) }
        end

        def too_large = render_error("R413-CLUSTER-001", "Payload too large", status: :content_too_large)

        def invalid = render_error("R422-CLUSTER-001", "Invalid snapshot", status: :unprocessable_content)

        # Reads at most max+1 bytes even from a gzip bomb (same guard as the servers samples).
        def parse_payload(max)
          bytes = request.body.read.to_s.b
          data = bytes.byteslice(0, 2) == GZIP_MAGIC ? Zlib::GzipReader.new(StringIO.new(bytes)).read(max + 1).to_s : bytes
          return :too_large if data.bytesize > max

          JSON.parse(data)
        rescue JSON::ParserError, Zlib::Error
          nil
        end
      end
    end
  end
end
