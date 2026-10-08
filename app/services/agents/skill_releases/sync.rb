# frozen_string_literal: true

module Agents
  module SkillReleases
    # Records the public releases the server has not seen yet (CYRA-912). Known versions are never
    # rewritten: a different sha256 for a published version means the release changed after the fact,
    # and the CLI must keep verifying against the first value.
    class Sync < ApplicationService
      def call
        entries = Feed.call
        known = SkillRelease.where(version: entries.map(&:version)).index_by(&:version)
        added = entries.filter_map do |entry|
          if (release = known[entry.version])
            warn_on_changed_hash(release, entry)
            next
          end

          create(entry)
        end
        Result.ok(added:)
      rescue Feed::Error => e
        Rails.logger.warn("[Agents::SkillReleases::Sync] releases not read: #{e.message}")
        Result.err(AppError.new("cyi skill releases unreadable: #{e.message}", code: "R502-AGENT-001", status: :bad_gateway))
      end

      private

      # A concurrent job or the Valhalla button may have saved the version first: skip, never 500.
      def create(entry)
        SkillRelease.create!(entry.to_h)
        entry.version
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
        Rails.logger.warn("[Agents::SkillReleases::Sync] #{entry.version} not saved: #{e.class}")
        nil
      end

      def warn_on_changed_hash(release, entry)
        return if release.sha256 == entry.sha256

        Rails.logger.warn("[Agents::SkillReleases::Sync] #{release.version}: GitHub sha256 changed, keeping the recorded one")
      end
    end
  end
end
