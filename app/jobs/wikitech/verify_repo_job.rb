# frozen_string_literal: true

module Wikitech
  # Checks on GitHub that the repository of a card exists and stores its public data (CYRA-1129).
  # A name misheard in a video gives a repository that does not exist: the card stays unconfirmed.
  class VerifyRepoJob < ApplicationJob
    queue_as :batch

    # GitHub allows 60 unauthenticated calls per hour: come back when it says so, as many times as needed.
    rescue_from Wikitech::GithubRepo::RateLimited do |error|
      retry_job(wait: error.retry_after.seconds + rand(0..59).seconds)
    end

    def perform(entry_id:)
      entry = Wikitech::Entry.find_by(id: entry_id)
      return if entry&.repo_url.blank?

      result = Wikitech::GithubRepo.call(repo_url: entry.repo_url)
      if result.ok?
        entry.update!(verification: :verified, repo_meta: result.value, repo_checked_at: Time.current)
        Wikitech::EmbedEntryJob.perform_later(entry_id: entry.id)
      elsif result.error.code == Wikitech::GithubRepo::NOT_FOUND
        entry.update!(verification: :unconfirmed, repo_checked_at: Time.current)
      else
        raise result.error
      end
    end
  end
end
