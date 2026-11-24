# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe SessionHealth::Ingest::Record, "PostgreSQL session update concurrency" do
  self.use_transactional_tests = false
  let!(:organization) { create(:organization) }
  let!(:project) { create(:project, organization: organization) }
  after { organization.destroy! if organization.persisted? }

  it "serializes competing initial and terminal deliveries into one terminal session" do
    sid = SecureRandom.uuid
    states = [ { "status" => "ok", "timestamp" => "2026-10-04T01:00:00Z" }, { "status" => "crashed", "timestamp" => "2026-10-04T01:01:00Z" } ]
    ready = Queue.new
    start = Queue.new
    threads = states.map do |state|
      Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          payload = state.merge("sid" => sid, "init" => true, "started" => "2026-10-04T01:00:00Z", "attrs" => { "release" => "concurrent" })
          items = SessionHealth::Ingest::Decode.call(type: "session", payload: payload).map { |value| { type: "session", value: value } }
          ready << true
          start.pop
          described_class.call(project: Projects::Project.find(project.id), items: items)
        end
      end
    end
    results = Timeout.timeout(15) do
      2.times { ready.pop }
      2.times { start << true }
      threads.map(&:value)
    end
    expect(results.sum(&:rejected)).to eq(0)
    expect(project.health_sessions.sole).to have_attributes(status: "crashed", errors_count: 1)
  ensure
    threads&.each { |thread| thread.kill if thread.alive? }
    threads&.each(&:join)
  end

  def session_items(sid, status: "ok", timestamp: "2026-10-04T01:00:00Z")
    payload = { "sid" => sid, "init" => true, "started" => "2026-10-04T01:00:00Z", "timestamp" => timestamp, "status" => status, "attrs" => { "release" => "concurrent" } }
    SessionHealth::Ingest::Decode.call(type: "session", payload: payload).map { |value| { type: "session", value: value } }
  end

  def backend_pid
    ApplicationRecord.connection.select_value("SELECT pg_backend_pid()")
  end

  # Runs the block on its own connection inside a transaction left open until `release` is signalled,
  # so every lock the block took stays held, as by a request stopped half way. Returns the thread and
  # its backend pid once the block is done.
  def hold(release)
    held = Queue.new
    thread = Thread.new do
      ApplicationRecord.connection_pool.with_connection do
        ApplicationRecord.transaction do
          yield
          held << backend_pid
          release.pop
        end
      end
    end
    [ thread, Timeout.timeout(15) { held.pop } ]
  end

  # Starts the block on its own connection and returns the thread with its backend pid.
  def in_thread(&block)
    started = Queue.new
    thread = Thread.new do
      ApplicationRecord.connection_pool.with_connection do
        started << backend_pid
        block.call
      end
    end
    [ thread, Timeout.timeout(15) { started.pop } ]
  end

  # Returns once PostgreSQL reports `waiter` queued on a session lock that `holder` holds. Asks the
  # server instead of timing the thread, so a waiter that has not reached the lock yet never passes.
  def await_blocked(waiter, holder)
    sql = <<~SQL.squish
      SELECT #{Integer(holder)} = ANY(pg_blocking_pids(#{Integer(waiter)}))
        AND EXISTS (SELECT 1 FROM pg_locks WHERE pid = #{Integer(waiter)} AND locktype = 'advisory' AND NOT granted)
    SQL
    Timeout.timeout(15) { Thread.pass until ApplicationRecord.connection.select_value(sql) }
  end

  # Runs on this thread, failing at once instead of queueing if any lock it needs is held elsewhere.
  def without_waiting(&block)
    ApplicationRecord.transaction do
      ApplicationRecord.connection.execute("SET LOCAL lock_timeout = '50ms'")
      block.call
    end
  end

  def finish(thread)
    Timeout.timeout(15) { thread.value }
  end

  it "admits parallel deliveries of one project with exact per-session outcomes and final counts" do
    shared = SecureRandom.uuid
    batches = Array.new(4) { Array.new(3) { SecureRandom.uuid } }
    start = Queue.new
    threads = batches.map do |sids|
      in_thread do
        items = (sids + [ shared ]).flat_map { |sid| session_items(sid) }
        start.pop
        described_class.call(project: Projects::Project.find(project.id), items: items)
      end.first
    end
    results = Timeout.timeout(15) do
      4.times { start << true }
      threads.map(&:value)
    end
    expect(results.sum(&:accepted)).to eq(13)
    expect(results.sum(&:duplicates)).to eq(3)
    expect(results.sum(&:rejected) + results.sum(&:stale)).to eq(0)
    expect(project.health_sessions.pluck(:sid)).to match_array(batches.flatten + [ shared ])
  ensure
    threads&.each { |thread| thread.kill if thread.alive? }
    threads&.each(&:join)
  end

  it "lets another session of the same project finish while a delivery is held half way, and queues only the same session" do
    held_sid = SecureRandom.uuid
    release = Queue.new
    holder, holder_pid = hold(release) { described_class.call(project: Projects::Project.find(project.id), items: session_items(held_sid)) }

    other = without_waiting { described_class.call(project: Projects::Project.find(project.id), items: session_items(SecureRandom.uuid)) }
    expect(other.accepted).to eq(1)

    same, same_pid = in_thread { described_class.call(project: Projects::Project.find(project.id), items: session_items(held_sid, status: "crashed", timestamp: "2026-10-04T01:01:00Z")) }
    await_blocked(same_pid, holder_pid)
    release << true
    finish(holder)
    expect(finish(same).accepted).to eq(1)
    expect(project.health_sessions.find_by!(sid: held_sid)).to have_attributes(status: "crashed", observed_update_count: 2)
  ensure
    release&.push(true)
    [ holder, same ].compact.each { |thread| thread.join(15) || thread.kill }
  end

  context "against the pruning job, where whichever holds the session lock first wins" do
    let(:sid) { SecureRandom.uuid }

    before do
      @global_created = !Settings::Global.exists?
      Settings::Global.instance
      travel_to(40.days.ago) { described_class.call(project: project, items: session_items(sid)) }
    end

    after { Settings::Global.delete_all if @global_created }

    it "prunes an expired session after a delivery that held it first, without renewing its age" do
      release = Queue.new
      holder, holder_pid = hold(release) { described_class.call(project: Projects::Project.find(project.id), items: session_items(sid, status: "exited", timestamp: "2026-10-04T01:01:00Z")) }
      pruner, pruner_pid = in_thread { SessionHealth::PruneJob.perform_now }
      await_blocked(pruner_pid, holder_pid)
      release << true
      finish(holder)
      finish(pruner)
      expect(project.health_sessions.where(sid: sid)).to be_empty
    ensure
      release&.push(true)
      [ holder, pruner ].compact.each { |thread| thread.join(15) || thread.kill }
    end

    it "starts a new session for a delivery that waited on the pruning, never writing the deleted row back" do
      pruned_id = project.health_sessions.find_by!(sid: sid).id
      release = Queue.new
      holder, holder_pid = hold(release) { SessionHealth::PruneJob.perform_now }
      delivery, delivery_pid = in_thread { described_class.call(project: Projects::Project.find(project.id), items: session_items(sid, status: "exited", timestamp: "2026-10-04T01:01:00Z")) }
      await_blocked(delivery_pid, holder_pid)
      release << true
      finish(holder)
      expect(finish(delivery).accepted).to eq(1)
      expect(project.health_sessions.sole).to have_attributes(sid: sid, status: "exited", observed_update_count: 1)
      expect(project.health_sessions.sole.id).not_to eq(pruned_id)
      expect(project.health_sessions.sole.created_at).to be > 1.day.ago
    ensure
      release&.push(true)
      [ holder, delivery ].compact.each { |thread| thread.join(15) || thread.kill }
    end
  end
end
