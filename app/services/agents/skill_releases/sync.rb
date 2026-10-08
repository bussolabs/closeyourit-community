# frozen_string_literal: true

module Agents
  module SkillReleases
    # Mirrors the public releases (CYRA-912): records the versions the server has not seen yet, and
    # withdraws or restores known ones as GitHub stops or starts listing them. GitHub is the only place
    # where a version is withdrawn, so every install follows the publisher. Known versions are never
    # rewritten: a different sha256 means the release changed after the fact, and the CLI must keep
    # verifying against the first value.
    class Sync < ApplicationService
      def call
        listing = Feed.call
        known = SkillRelease.where(version: listing.entries.map(&:version)).index_by(&:version)
        added = listing.entries.filter_map do |entry|
          if (release = known[entry.version])
            warn_on_changed_hash(release, entry)
            next
          end

          create(entry)
        end
        Result.ok(added:, **follow_withdrawals(listing.listed))
      rescue Feed::Error => e
        Rails.logger.warn("[Agents::SkillReleases::Sync] releases not read: #{e.message}")
        Result.err(AppError.new("cyi skill releases unreadable: #{e.message}", code: "R502-AGENT-001", status: :bad_gateway))
      end

      private

      # An empty list is far more likely a broken mirror than a publisher who withdrew everything.
      def follow_withdrawals(listed)
        if listed.empty?
          Rails.logger.warn("[Agents::SkillReleases::Sync] no published version listed, withdrawals left as they are")
          return { withdrawn: [], restored: [] }
        end

        withdrawn = SkillRelease.where(withdrawn_at: nil).where.not(version: listed.to_a).pluck(:version)
        restored = SkillRelease.where.not(withdrawn_at: nil).where(version: listed.to_a).pluck(:version)
        SkillRelease.where(version: withdrawn).update_all(withdrawn_at: Time.current)
        SkillRelease.where(version: restored).update_all(withdrawn_at: nil, withdrawn_by_id: nil)
        { withdrawn: withdrawn.sort_by { Gem::Version.new(_1) }, restored: restored.sort_by { Gem::Version.new(_1) } }
      end

      # A concurrent run may have saved the version first: skip, never fail the whole sync.
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
