# frozen_string_literal: true

module Github
  module Webhooks
    # Evento `push`: se il ref è un tag (refs/tags/*), tenta il binding tag→release.
    # CYRA-1154 — a push to the default branch checks whether the delivered proposals still merge.
    class Push < Base
      def call
        ref = value_at(@payload, "ref").to_s
        return bind_tag(ref.delete_prefix("refs/tags/")) if ref.start_with?("refs/tags/")
        return Result.ok(nil) unless ref.start_with?("refs/heads/")

        check_delivered_proposals(ref.delete_prefix("refs/heads/"))
      end

      private

      # The commit titles come from the delivery itself: that is what landed, not what we last read.
      def check_delivered_proposals(branch)
        repo = repository
        return Result.ok(nil) if repo.nil? || !repo.sync_enabled? || branch != repo.default_branch
        return Result.ok(nil) if value_at(@payload, "deleted") == true

        Agents::ConflictChecks::Schedule.call(repository: repo, main_sha: value_at(@payload, "after"),
                                              commits: @payload["commits"])
      end
    end
  end
end
