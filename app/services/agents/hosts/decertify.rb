# frozen_string_literal: true

module Agents
  module Hosts
    # B.1b — Revoca la certificazione di un host: torna ineleggibile all'esecuzione (senza revocarlo del
    # tutto, che è un'altra azione — Revoke). Azzera `certified_at`/`certified_by`. Idempotente.
    class Decertify < ApplicationService
      def initialize(host:)
        @host = host
      end

      def call
        @host.update!(certified_at: nil, certified_by: nil)
        Result.ok(@host)
      end
    end
  end
end
