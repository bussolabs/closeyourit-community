# frozen_string_literal: true

module Servers
  # Ingest asincrono di un push dell'agent: il controller ha già risolto l'host (sincrono, per il
  # 403 ai revocati), qui il lavoro pesante. Host sparito nel frattempo → no-op.
  class IngestJob < ApplicationJob
    queue_as :servers_ingest

    def perform(host_id:, payload:)
      host = Servers::Host.find_by(id: host_id)
      return if host.nil? || host.revoked?

      Servers::Ingest::Record.call(host: host, payload: payload)
    end
  end
end
