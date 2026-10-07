# frozen_string_literal: true

require "rails_helper"

RSpec.describe Coworkers::ExecuteJob, "runtime stream boundaries" do
  let(:puck) { Coworkers::Puck.create!(account: create(:account), organization: create(:organization), name: "Researcher", instructions: "Cite sources") }
  let(:run) { puck.runs.create!(kind: "task", input: "Read public sources", status: "running") }
  let(:job) { described_class.new.tap { |value| value.instance_variable_set(:@run, run) } }

  def consume(events)
    reader, writer = IO.pipe
    events.each { |event| writer.write(event.to_json + "\n") }
    writer.close
    job.send(:consume, reader)
  ensure
    reader&.close unless reader&.closed?
    writer&.close unless writer&.closed?
  end

  it "assembles partial writes, tool results and a completed answer from a real pipe" do
    consume([
      { "type" => "delta", "text" => "First " }, { "type" => "delta", "text" => "part" },
      { "type" => "tool", "id" => "read-1", "name" => "read" },
      { "type" => "tool", "id" => "read-2", "name" => "read" },
      { "type" => "tool_result", "id" => "read-1", "success" => true },
      { "type" => "ignored-extension" },
      { "type" => "result", "success" => true, "output" => "Verified answer" },
      { "type" => "end", "code" => 0 }
    ])
    expect(run.reload).to have_attributes(status: "completed", output: "Verified answer")
    expect(run.tools.map { |tool| tool["success"] }).to eq([ true, false ])
  end

  it "marks an EOF before completion as interrupted and preserves partial output" do
    consume([ { "type" => "delta", "text" => "Partial answer" } ])
    expect(run.reload).to have_attributes(status: "failed", error_code: "runtime_interrupted", output: "Partial answer")
  end

  it "honors a stop request before reading pending runtime events" do
    run.update!(stop_requested: true)
    consume([ { "type" => "delta", "text" => "Must not appear" } ])
    expect(run.reload).to have_attributes(status: "stopped", output: "")
  end

  it "rejects a task proposal rather than creating nested work from a research stream" do
    expect do
      consume([ { "type" => "proposal", "proposal" => { "objective" => "Other task", "activities" => "Read", "limits" => "No writes" } } ])
    end.to raise_error(RuntimeError, "Invalid runtime proposal")
    expect(run.reload.proposed_task).to eq({})
  end

  it "fails an end marker without a preceding successful result" do
    consume([ { "type" => "tool", "id" => "read", "name" => "read" },
      { "type" => "tool_result", "id" => "read", "success" => true }, { "type" => "end", "code" => 0 } ])
    expect(run.reload).to have_attributes(status: "failed", error_code: "runtime_failed")
  end

  it "bounds an unterminated output line without deadlocking the writer" do
    reader, writer = IO.pipe
    producer = Thread.new do
      writer.write("x" * (Coworkers::ExecuteJob::MAX_LINE_BYTES + 1))
    rescue Errno::EPIPE, IOError
      nil
    ensure
      writer.close unless writer.closed?
    end
    expect { job.send(:consume, reader) }.to raise_error(RuntimeError, "Runtime output exceeded limit")
  ensure
    reader&.close unless reader&.closed?
    producer&.join
  end

  it "fails a missing local runtime without replacing the saved partial answer" do
    original = ENV.to_h.slice("COWORKERS_ENABLED", "COWORKERS_RUNTIME", "COWORKERS_RUNTIME_ROOT")
    Dir.mktmpdir("coworker-runtime-") do |directory|
      ENV["COWORKERS_ENABLED"] = "true"
      ENV["COWORKERS_RUNTIME"] = "local"
      ENV["COWORKERS_RUNTIME_ROOT"] = directory
      run.update!(status: "queued", output: "Saved partial answer")
      expect { described_class.perform_now(run.id) }.to raise_error(RuntimeError, "Runtime bridge not found")
      expect(run.reload).to have_attributes(status: "failed", error_code: "runtime_unavailable", output: "Saved partial answer")
      expect { described_class.perform_now(SecureRandom.uuid) }.to raise_error(ActiveRecord::RecordNotFound)
    end
  ensure
    %w[COWORKERS_ENABLED COWORKERS_RUNTIME COWORKERS_RUNTIME_ROOT].each { |key| original.key?(key) ? ENV[key] = original[key] : ENV.delete(key) }
  end

  it "terminates only the owned child process and tolerates a child that already exited" do
    pid = Process.spawn(RbConfig.ruby, "-e", "sleep 30", pgroup: true, out: File::NULL, err: File::NULL)
    process = Process.detach(pid)
    job.send(:terminate, process)
    expect(process.join(1)).not_to be_nil
    expect { job.send(:terminate, process) }.not_to raise_error
  ensure
    if process&.alive?
      Process.kill("KILL", pid)
      process.join
    end
  end
end
