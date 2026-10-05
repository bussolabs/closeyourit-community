# frozen_string_literal: true

module Clusters
  # Live refresh of an open cluster page (CYAG-22). Stream names come only from Realtime::Streams, so
  # the tenant isolation is in the name. Called after the snapshot is committed.
  module Broadcast
    module_function

    def refresh(cluster)
      Turbo::StreamsChannel.broadcast_refresh_to(Realtime::Streams.cluster(cluster))
    end
  end
end
