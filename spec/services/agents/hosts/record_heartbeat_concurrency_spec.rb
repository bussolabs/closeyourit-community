# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe Agents::Hosts::RecordHeartbeat, "concorrenza PostgreSQL reale" do
  self.use_transactional_tests = false

  let!(:organization) { create(:organization) }
  let!(:project) { create(:project, organization:, key: "CYRA") }
  let!(:host) { create(:agent_host, organization:) }

  after do
    organization.destroy! if organization.persisted?
  end

  it "rilegge sotto lock e rifiuta una revoca committata dopo il lookup active" do
    resolved = Queue.new
    release = Queue.new
    heartbeat_thread = nil

    allow_any_instance_of(described_class).to receive(:after_host_resolved).and_wrap_original do |original, value|
      resolved << true
      release.pop
      original.call(value)
    end

    heartbeat_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        described_class.call(
          project: Projects::Project.find(project.id),
          payload: {
            host_id: host.id, repositories: [ "CYRA" ], host_status: "busy",
            active_runs: [], runtimes: [], running: 0, slots: 1
          },
          at: Time.current
        )
      end
    end

    Timeout.timeout(5) { resolved.pop }
    Agents::Hosts::Revoke.call(host: Agents::Host.find(host.id))
    release << true

    result = Timeout.timeout(10) { heartbeat_thread.value }
    expect(result).to be_err
    expect(result.error).to have_attributes(code: "R404-AGENT-003", status: :not_found)
    expect(host.reload).to be_revoked
    expect(host.last_heartbeat_at).to be_nil
  ensure
    release << true
    if heartbeat_thread
      heartbeat_thread.kill if heartbeat_thread.alive?
      heartbeat_thread.join
    end
  end
end
