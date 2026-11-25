# frozen_string_literal: true

require "rails_helper"
require "timeout"

# CYRA-1241 — due primi eventi dello stesso utente in parallelo. Con le transazioni dei test il secondo
# vedrebbe le scritture del primo: qui ognuno ha la propria connessione e il proprio commit, come due
# worker veri.
RSpec.describe Errors::Ingest::Record, "users_count under concurrent deliveries" do
  self.use_transactional_tests = false
  let!(:organization) { create(:organization) }
  let!(:project) { create(:project, organization: organization) }

  after { organization.destroy! if organization.persisted? }

  def payload(event_id, user: { "id" => "user-1" })
    { "event_id" => event_id, "message" => "boom", "user" => user }
  end

  def waiting_on_lock?(pid)
    ApplicationRecord.connection.select_value("SELECT wait_event_type FROM pg_stat_activity WHERE pid = #{Integer(pid)}") == "Lock"
  end

  it "counts the same user once when two first events arrive together" do
    # The group already exists (an anonymous event): the race is on the user, not on the fingerprint.
    described_class.call(project: project, payload: payload("0" * 32, user: nil))

    ready = Queue.new
    release = Queue.new
    first = Thread.new do
      ApplicationRecord.connection_pool.with_connection do
        # The outer transaction keeps the first delivery open after it has added the user.
        ApplicationRecord.transaction do
          described_class.call(project: project, payload: payload("1" * 32))
          ready << true
          release.pop
        end
      end
    end
    Timeout.timeout(15) { ready.pop }

    second_pid = Queue.new
    second = Thread.new do
      ApplicationRecord.connection_pool.with_connection do
        second_pid << ApplicationRecord.connection.select_value("SELECT pg_backend_pid()")
        described_class.call(project: project, payload: payload("2" * 32))
      end
    end
    # The second delivery is parked on the unique index until the first one commits.
    pid = Timeout.timeout(15) { second_pid.pop }
    Timeout.timeout(15) { Thread.pass until waiting_on_lock?(pid) }

    release << true
    Timeout.timeout(15) { first.value }
    Timeout.timeout(15) { second.value }

    group = project.error_groups.sole
    expect(group.events.count).to eq(3)
    expect(group.users_count).to eq(1)
    expect(group.group_users.count).to eq(1)
  ensure
    [ first, second ].compact.each do |thread|
      thread.kill if thread.alive?
      thread.join
    end
  end
end
