# frozen_string_literal: true

module Agents
  module Hosts
    # B.1b — Certifica un host: è il via libera ESPLICITO e umano perché una macchina diventi eleggibile
    # all'esecuzione (gate Agents::Hosts::Eligibility, che richiede `host.certified?`). Registra chi ha
    # abilitato (`certified_by`) per audit. Idempotente: ri-certificare aggiorna solo il timestamp.
    class Certify < ApplicationService
      def initialize(host:, actor:)
        @host = host
        @actor = actor
      end

      def call
        @host.update!(certified_at: Time.current, certified_by: @actor)
        Result.ok(@host)
      rescue ActiveRecord::RecordInvalid => e
        Result.err(AppError.new(e.message, code: "R422-AGENT-007", details: e.record.errors.to_hash))
      end
    end
  end
end
