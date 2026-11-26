# frozen_string_literal: true

require "rails_helper"
require "timeout"

# CYRA-1154 · Scenario 9 — two checks of the same proposal see the conflict at the same instant.
# Both read CONFLICTING from GitHub, held and released together, then race for the send back on
# separate connections: the database decides, so this needs real PostgreSQL and no transactional tests.
RSpec.describe Agents::ConflictChecks::SendBack, "two checks racing on the same proposal" do
  self.use_transactional_tests = false

  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let!(:repository) do
    create(:github_repository, project:, full_name: "bussolabs/closeyourit-rails", default_branch: "main")
  end
  let!(:in_review) { create(:ticket_status, :in_review, organization:) }
  let!(:working) { create(:ticket_status, :in_progress, organization:) }
  let!(:ticket) { create(:ticket, organization:, project:, status: in_review, with_agent_workflow: true) }
  let!(:candidate) { delivered_waiting!(ticket:, repository:) }
  let!(:check) { create(:agent_conflict_check, delivery_candidate: candidate, organization:) }

  # No transaction rolls these rows back: the reporter the ticket factory adds as a member goes too, or the
  # next run collides on its email and leaves the organization and its repository behind for other specs.
  after do
    owner = Organizations::Organization.find_by(id: organization.id)
    next if owner.nil?

    account_ids = owner.memberships.pluck(:account_id) + owner.agent_hosts.filter_map(&:service_account_id) +
                  Agents::Attempt.joins(:workflow).where(agents_workflows: { ticket_id: owner.tickets.select(:id) })
                                 .pluck(:service_account_id)
    owner.tickets.find_each(&:destroy!)
    owner.reload.destroy!
    Accounts::Account.where(id: account_ids.compact).destroy_all
  end

  it "sends the work back once and writes one notice" do
    waiting = 0
    mutex = Mutex.new
    rendezvous = ConditionVariable.new
    sent_back_calls = 0
    threads = []
    response = merge_state("CONFLICTING")

    # The GitHub read is the last step outside the transaction: both hold there until both arrived.
    client = Object.new
    client.define_singleton_method(:pull_request_state) do |*|
      mutex.synchronize do
        waiting += 1
        rendezvous.broadcast
        rendezvous.wait(mutex) while waiting < 2
      end
      response
    end
    allow(described_class).to receive(:call).and_wrap_original do |original, **args|
      mutex.synchronize { sent_back_calls += 1 }
      original.call(**args)
    end

    threads = Array.new(2) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Agents::ConflictChecks::Run.call(check: Agents::ConflictCheck.find(check.id), client:)
        end
      end
    end
    Timeout.timeout(20) { threads.each(&:value) }

    expect(sent_back_calls).to eq(2)
    expect(check.reload).to have_attributes(state: "sent_back")
    expect(ticket.events.where(action: "pull_request_conflict").count).to eq(1)
    expect(ticket.events.where(action: "status_changed").count).to eq(1)
    expect(ticket.agent_workflow.reload).to have_attributes(conflict_resolution_requested_at: be_present,
                                                            autopilot_completed_at: nil, review_candidate_id: nil)
  ensure
    threads.each do |thread|
      thread.kill if thread.alive?
      thread.join
    end
  end

  # GitHub's answer can flip between two reads: the MERGEABLE that lands after the send back must not
  # close the row as clean, or the agent would lose the titles and the round would look unused.
  it "keeps the send back when the other read answers MERGEABLE after it" do
    waiting = 0
    mutex = Mutex.new
    rendezvous = ConditionVariable.new
    threads = []
    meet = lambda do
      mutex.synchronize do
        waiting += 1
        rendezvous.broadcast
        rendezvous.wait(mutex) while waiting < 2
      end
    end

    conflict_answer = merge_state("CONFLICTING")
    clean_answer = merge_state("MERGEABLE")
    sent = false
    committed = ConditionVariable.new
    allow(described_class).to receive(:call).and_wrap_original do |original, **args|
      original.call(**args).tap do
        mutex.synchronize do
          sent = true
          committed.broadcast
        end
      end
    end

    conflicting = Object.new
    conflicting.define_singleton_method(:pull_request_state) do |*|
      meet.call
      conflict_answer
    end
    # The MERGEABLE read waits for the send back to commit, then answers: the order the guard is for.
    mergeable = Object.new
    mergeable.define_singleton_method(:pull_request_state) do |*|
      meet.call
      mutex.synchronize { committed.wait(mutex) until sent }
      clean_answer
    end

    threads = [ conflicting, mergeable ].map do |client|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Agents::ConflictChecks::Run.call(check: Agents::ConflictCheck.find(check.id), client:)
        end
      end
    end
    Timeout.timeout(20) { threads.each(&:value) }

    expect(check.reload).to have_attributes(state: "sent_back", handled_at: be_present)
    expect(ticket.events.where(action: "pull_request_conflict").count).to eq(1)
    expect(ticket.agent_workflow.reload).to have_attributes(conflict_resolution_requested_at: be_present,
                                                            conflict_resolution_used_at: be_present)
  ensure
    threads.each do |thread|
      thread.kill if thread.alive?
      thread.join
    end
  end
end
