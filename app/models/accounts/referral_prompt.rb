# frozen_string_literal: true

module Accounts
  # CYRA-1162 — the request to recommend the app, one row per person. It appears after a useful
  # moment, at most MAX_SHOWS times, and never again once declined. Reserving a show is one UPDATE
  # that only succeeds under the cap, so two pages opened together cannot both show it.
  class ReferralPrompt < ApplicationRecord
    self.table_name = "accounts_referral_prompts"

    MAX_SHOWS = 2
    FIRST_THRESHOLD = 10
    # «Later» moves the threshold this far past the tickets already closed: 10 becomes 50.
    POSTPONE_STEP = 40
    # A ticket an agent resolved counts as the moment only while the news is fresh.
    AGENT_MOMENT_WINDOW = 7.days
    # The star goes to the public community copy, the one anyone can see.
    STAR_URL = "https://github.com/#{App::SelfHosted::REPO}".freeze

    belongs_to :account, class_name: "Accounts::Account", inverse_of: :referral_prompt

    # One more ticket brought to a done status by this person. Never goes down: reopening is not undoing.
    def self.count_closed!(account)
      upsert({ account_id: account.id, closed_tickets_count: 1 }, unique_by: :account_id,
             on_duplicate: Arel.sql("closed_tickets_count = accounts_referral_prompts.closed_tickets_count + 1, " \
                                    "updated_at = CURRENT_TIMESTAMP"))
    end

    # Takes one show if a moment is due: the threshold is reached, or an agent resolved an error
    # at `agent_moment_at` after the last show (and the person did not ask to wait). Returns the
    # number of this show, or nil when nothing is due or another page got there first.
    def self.reserve(account:, agent_moment_at: nil)
      insert_all([ { account_id: account.id } ], unique_by: :account_id)
      moment = "closed_tickets_count >= next_threshold"
      moment += " OR (postponed_at IS NULL AND (last_shown_at IS NULL OR last_shown_at < :agent_at))" if agent_moment_at
      due = where(account_id: account.id, declined_at: nil).where(shown_count: ...MAX_SHOWS)
                                                          .where(moment, agent_at: agent_moment_at)
      # A threshold show moves the threshold too, or the next page would count the same moment again.
      reserved = due.update_all([ "shown_count = shown_count + 1, last_shown_at = :now, updated_at = :now, " \
                                  "next_threshold = CASE WHEN closed_tickets_count >= next_threshold " \
                                  "THEN closed_tickets_count + :step ELSE next_threshold END",
                                  { now: Time.current, step: POSTPONE_STEP } ])
      return nil unless reserved == 1

      where(account_id: account.id).pick(:shown_count)
    end

    def self.postpone!(account)
      prompt = create_or_find_by!(account: account)
      prompt.update!(postponed_at: Time.current,
                     next_threshold: [ prompt.next_threshold, prompt.closed_tickets_count + POSTPONE_STEP ].max)
    end

    def self.decline!(account)
      create_or_find_by!(account: account).update!(declined_at: Time.current)
    end

    # Nothing more to show: declined, or the cap is spent. Lets the page skip the write.
    def finished?
      declined_at? || shown_count >= MAX_SHOWS
    end

    def threshold_reached?
      closed_tickets_count >= next_threshold
    end

    def agent_moment_open?(agent_moment_at)
      postponed_at.nil? && (last_shown_at.nil? || last_shown_at < agent_moment_at)
    end
  end
end
