# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe Ingest::EventLock, "PostgreSQL transaction locks" do
  include ActiveJob::TestHelper
  self.use_transactional_tests = false
  let!(:organization) { create(:organization) }
  let!(:project) { create(:project, organization: organization) }

  after { organization.destroy! if organization.persisted? }

  it "returns retryable contention and releases the identity lock after commit" do
    ready = Queue.new
    release = Queue.new
    thread = Thread.new do
      ApplicationRecord.connection_pool.with_connection do
        ApplicationRecord.transaction do
          described_class.acquire!(project_id: project.id, event_id: "same", domain: "errors")
          ready << true
          release.pop
        end
      end
    end
    Timeout.timeout(15) { ready.pop }
    ApplicationRecord.transaction do
      expect { described_class.acquire!(project_id: project.id, event_id: "same", domain: "errors") }.to raise_error(described_class::Busy)
      expect { described_class.acquire!(project_id: project.id, event_id: "same", domain: "logs") }.not_to raise_error
      expect { described_class.acquire!(project_id: SecureRandom.uuid, event_id: "same", domain: "errors") }.not_to raise_error
    end
    release << true
    Timeout.timeout(15) { thread.value }
    ApplicationRecord.transaction do
      expect { described_class.acquire!(project_id: project.id, event_id: "same", domain: "errors") }.not_to raise_error
    end
  ensure
    thread&.kill if thread&.alive?
    thread&.join
  end

  it "retries a staged error after contention and deduplicates its later cross-month replay" do
    event_id = "e" * 32
    staged = Errors::IngestPayload.create!(project: project, payload: { "event_id" => event_id, "message" => "retryable event" })
    ready = Queue.new
    release = Queue.new
    thread = Thread.new do
      ApplicationRecord.connection_pool.with_connection do
        ApplicationRecord.transaction do
          described_class.acquire!(project_id: project.id, event_id: event_id, domain: "errors")
          ready << true
          release.pop
        end
      end
    end
    Timeout.timeout(15) { ready.pop }
    expect { Errors::IngestJob.perform_now(payload_id: staged.id) }.to have_enqueued_job(Errors::IngestJob)
    expect(Errors::IngestPayload.exists?(staged.id)).to be(true)
    expect(project.error_events.count).to eq(0)
    release << true
    Timeout.timeout(15) { thread.value }
    perform_enqueued_jobs(only: Errors::IngestJob)
    expect(Errors::IngestPayload.exists?(staged.id)).to be(false)
    expect(project.error_events.count).to eq(1)
    travel_to(project.error_events.sole.created_at.next_month) do
      Errors::Ingest::Record.call(project: project, payload: { "event_id" => event_id, "message" => "later delivery" })
    end
    expect(project.error_events.count).to eq(1)
    expect(project.error_groups.sole.events_count).to eq(1)
  ensure
    thread&.kill if thread&.alive?
    thread&.join
  end
end
