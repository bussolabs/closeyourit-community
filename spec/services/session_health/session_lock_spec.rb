# frozen_string_literal: true

require "rails_helper"

RSpec.describe SessionHealth::SessionLock, "PostgreSQL session identity locks" do
  let(:project_id) { SecureRandom.uuid }

  # Advisory locks held by this connection, rebuilt as the bigint keys they were taken with.
  def held_keys
    ApplicationRecord.connection.select_values(<<~SQL.squish).map(&:to_i)
      SELECT (classid::bigint << 32) | objid::bigint FROM pg_locks
      WHERE locktype = 'advisory' AND objsubid = 1 AND granted AND pid = pg_backend_pid()
    SQL
  end

  def lock_binds
    binds = []
    callback = ->(*, payload) { binds << payload[:binds].map(&:value_for_database) if payload[:name] == "Session identity lock" }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    binds
  end

  it "takes no lock and runs no query for an empty or nil list of sids" do
    expect(lock_binds { described_class.acquire!(project_id: project_id, sids: []) }).to be_empty
    expect(lock_binds { described_class.acquire!(project_id: project_id, sids: nil) }).to be_empty
    expect(lock_binds { described_class.acquire!(project_id: project_id, sids: [ nil ]) }).to be_empty
    expect(held_keys).to be_empty
  end

  it "holds one lock per distinct session, ignoring case, repeats and missing sids" do
    sid = SecureRandom.uuid
    other = SecureRandom.uuid
    described_class.acquire!(project_id: project_id, sids: [ sid, sid.upcase, other, sid, nil ])
    expect(held_keys).to match_array(described_class.keys(project_id: project_id, sids: [ sid, other ]))
    expect(held_keys.size).to eq(2)
    expect(described_class.keys(project_id: project_id, sids: [ sid.upcase ])).to eq(described_class.keys(project_id: project_id, sids: [ sid ]))
  end

  it "scopes keys to the project" do
    sid = SecureRandom.uuid
    expect(described_class.keys(project_id: project_id, sids: [ sid ])).not_to eq(described_class.keys(project_id: SecureRandom.uuid, sids: [ sid ]))
  end

  it "takes the locks in ascending key order whatever order the sids arrive in" do
    sids = Array.new(8) { SecureRandom.uuid }
    keys = described_class.keys(project_id: project_id, sids: sids)
    expect(keys).to eq(keys.sort)
    forward = lock_binds { described_class.acquire!(project_id: project_id, sids: sids) }
    backward = lock_binds { described_class.acquire!(project_id: project_id, sids: sids.reverse) }
    expect(forward).to eq([ [ "{#{keys.join(",")}}" ] ])
    expect(backward).to eq(forward)
    expect(held_keys).to match_array(keys)
  end
end
