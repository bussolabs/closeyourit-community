# frozen_string_literal: true

module Vulnerabilities
  # Stores the publication date of versions that appeared in the project less than 72 hours ago
  # (CYRA-1167). Older versions are never asked: past 72 hours the warning cannot apply. A failure
  # leaves the date empty for the next daily scan and silences that registry for the rest of the run.
  class RecordReleaseDates < ApplicationService
    def initialize(packages:, client: Registry::Client.new, now: Time.current)
      @packages = packages
      @client = client
      @now = now
    end

    def call
      failed = Set.new
      rows = missing_coordinates.filter_map do |ecosystem, name, version|
        next if failed.include?(ecosystem)

        released_at = @client.released_at(ecosystem:, name:, version:)
        { ecosystem:, name:, version:, released_at: } if released_at
      rescue Registry::Client::Error => e
        failed << ecosystem
        Rails.logger.warn("[vulnerabilities] release date skipped for #{ecosystem}: #{e.message}")
        nil
      end

      PackageRelease.insert_all(rows, unique_by: %i[ecosystem name version]) if rows.any?
      Result.ok(rows.size)
    end

    private

    def missing_coordinates
      since = @now - PackageRelease::RECENT_WINDOW
      wanted = @packages.select { |package| package.created_at > since }.map(&:osv_key).uniq
      return [] if wanted.empty?

      known = PackageRelease.where(name: wanted.map(&:second)).pluck(:ecosystem, :name, :version).to_set
      wanted.reject { |coordinates| known.include?(coordinates) }
    end
  end
end
