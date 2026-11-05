# frozen_string_literal: true

require "rails_helper"

# CYRA-1162 — the request to recommend the app: shown after a useful moment, at most twice, never
# again once declined. The reservation is the guard against two pages opened together.
RSpec.describe Accounts::ReferralPrompt do
  let(:account) { create(:account) }

  def prompt = described_class.find_by(account:)

  describe ".count_closed!" do
    it "starts the row at one and adds one per closed ticket" do
      described_class.count_closed!(account)
      described_class.count_closed!(account)

      expect(prompt.closed_tickets_count).to eq(2)
      expect(prompt.next_threshold).to eq(described_class::FIRST_THRESHOLD)
    end
  end

  describe ".reserve" do
    it "reserves nothing before any moment" do
      expect(described_class.reserve(account:)).to be_nil
      expect(prompt.shown_count).to eq(0)
    end

    it "reserves one show when the threshold is reached, and moves the threshold" do
      described_class.create!(account:, closed_tickets_count: 10)

      expect(described_class.reserve(account:)).to eq(1)
      expect(prompt.next_threshold).to eq(50)
      expect(described_class.reserve(account:)).to be_nil
    end

    it "takes an agent moment once" do
      resolved_at = 1.hour.ago

      expect(described_class.reserve(account:, agent_moment_at: resolved_at)).to eq(1)
      expect(described_class.reserve(account:, agent_moment_at: resolved_at)).to be_nil
      expect(prompt.shown_count).to eq(1)
    end

    it "never goes past two shows" do
      described_class.create!(account:, closed_tickets_count: 500, shown_count: 2)

      expect(described_class.reserve(account:, agent_moment_at: 1.minute.ago)).to be_nil
      expect(prompt.shown_count).to eq(2)
    end

    it "shows nothing to a person who declined, whatever the threshold" do
      described_class.create!(account:, closed_tickets_count: 500, declined_at: 1.day.ago)

      expect(described_class.reserve(account:, agent_moment_at: 1.minute.ago)).to be_nil
    end

    it "waits for the higher threshold after «later», agent moments included" do
      described_class.create!(account:, closed_tickets_count: 12, next_threshold: 50, postponed_at: 1.day.ago,
                              shown_count: 1, last_shown_at: 2.days.ago)

      expect(described_class.reserve(account:, agent_moment_at: 1.minute.ago)).to be_nil

      prompt.update!(closed_tickets_count: 50)
      expect(described_class.reserve(account:)).to eq(2)
    end

    # Both pages read the row before either reserved: the UPDATE condition is what keeps it to one.
    it "lets only one of two pages opened together take the show" do
      described_class.create!(account:, closed_tickets_count: 10)
      first_read = prompt
      second_read = prompt
      expect([ first_read.finished?, second_read.finished? ]).to eq([ false, false ])

      results = [ described_class.reserve(account:), described_class.reserve(account:) ]

      expect(results).to eq([ 1, nil ])
      expect(prompt.shown_count).to eq(1)
    end
  end

  describe ".postpone!" do
    it "raises the threshold from 10 to 50" do
      described_class.create!(account:, closed_tickets_count: 10)

      described_class.postpone!(account)

      expect(prompt.next_threshold).to eq(50)
      expect(prompt.postponed_at).to be_present
    end

    it "keeps the next threshold ahead of the tickets already closed" do
      described_class.create!(account:, closed_tickets_count: 60)

      described_class.postpone!(account)

      expect(prompt.next_threshold).to eq(100)
    end
  end

  describe ".decline!" do
    it "turns the prompt off for good" do
      described_class.decline!(account)

      expect(prompt).to be_finished
      expect(account.reload.referral_prompt.declined_at).to be_present
    end
  end
end
