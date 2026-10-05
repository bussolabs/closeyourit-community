# frozen_string_literal: true

module Certification
  class Guard
    CONNECTION_OVERRIDES = %w[PGSERVICE PGSERVICEFILE PGDATABASE PGHOSTADDR PGOPTIONS TEST_ENV_NUMBER].freeze
    LOOPBACK_HOSTS = [ "localhost", "127.0.0.1", "::1" ].freeze

    def initialize(env = ENV)
      @env = env
    end

    def validate!
      raise ArgumentError, "Certification requires the test environment" unless @env["RAILS_ENV"] == "test"

      run_id = @env["CERTIFICATION_RUN_ID"].to_s
      raise ArgumentError, "Invalid certification run identifier" unless run_id.match?(/\A[0-9a-f]{16}\z/)
      raise ArgumentError, "Certification slot does not match this run" unless @env["TEST_SLOT"] == "_cert_#{run_id}"
      raise ArgumentError, "Database connection overrides are not allowed" if connection_override?
      raise ArgumentError, "Certification requires a local PostgreSQL host" unless local_host?(@env["PGHOST"])

      run_id
    end

    def local_host?(host)
      host.nil? || host.empty? || LOOPBACK_HOSTS.include?(host) || (host.start_with?("/") && !host.include?(","))
    end

    private

    def connection_override?
      CONNECTION_OVERRIDES.any? { |key| @env.key?(key) } || @env.keys.any? { |key| key.match?(/(?:\A|_)DATABASE_URL\z/) }
    end
  end
end
