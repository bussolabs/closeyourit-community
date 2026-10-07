# frozen_string_literal: true

require "rails_helper"

RSpec.describe Coworkers::ExecuteJob, "runtime process and event edges" do
  let(:puck) { Coworkers::Puck.create!(account: create(:account), organization: create(:organization), name: "Researcher", instructions: "Cite sources") }
  let(:run) { puck.runs.create!(kind: "chat", input: "Hello", status: "running") }
  let(:job) { described_class.new.tap { |value| value.instance_variable_set(:@run, run) } }

  before { allow(Coworkers).to receive(:enabled?).and_return(true) }

  def pipe_with(events, close: true)
    reader, writer = IO.pipe
    events.each { |event| writer.write(event.to_json + "\n") }
    writer.close if close
    [ reader, writer ]
  end

  describe "launching the runtime" do
    let(:finished) { [ { "type" => "result", "success" => true, "output" => "Done" }, { "type" => "end", "code" => 0 } ] }

    around do |example|
      Dir.mktmpdir("coworker-runtime-") do |directory|
        File.write(File.join(directory, "bridge.mjs"), "")
        @runtime_root = Pathname.new(directory)
        example.run
      end
    end

    before do
      allow(Coworkers).to receive_messages(remote?: false, runtime_root: @runtime_root)
      run.update!(status: "queued")
    end

    def launch(stdin:, process:)
      stdout, = pipe_with(finished)
      allow(Open3).to receive(:popen2) do |_env, command, *_args, **_options, &block|
        expect(command).to eq("node")
        block.call(stdin, stdout, process)
      end
      described_class.perform_now(run.id)
    ensure
      stdout&.close
    end

    it "sends the request on the runtime's input and closes it after a finished process" do
      stdin = StringIO.new
      launch(stdin: stdin, process: instance_double(Process::Waiter, alive?: false))
      expect(JSON.parse(stdin.string.lines.first)).to include("kind" => "chat")
      expect(stdin).to be_closed
      expect(run.reload).to have_attributes(status: "completed", output: "Done")
    end

    it "tolerates an input already closed and no process handle" do
      # No `close` stub: closing an input that is already closed would fail the example.
      stdin = instance_double(IO, write: nil, flush: nil, closed?: true)
      launch(stdin: stdin, process: nil)
      expect(stdin).to have_received(:write).once
      expect(run.reload.status).to eq("completed")
    end

    it "terminates a process still alive and kills its group when it ignores TERM" do
      process = instance_double(Process::Waiter, alive?: true, pid: 4242, join: nil)
      allow(Process).to receive(:kill)
      launch(stdin: StringIO.new, process: process)
      expect(Process).to have_received(:kill).with("TERM", 4242)
      expect(Process).to have_received(:kill).with("KILL", -4242)
    end
  end

  describe "reading the runtime output" do
    it "interrupts a runtime that stays silent past its deadline" do
      allow(Coworkers::Limits).to receive(:deadline).and_return(-19)
      reader, writer = pipe_with([], close: false)
      job.send(:consume, reader)
      expect(run.reload).to have_attributes(status: "interrupted", error_code: "timeout")
    ensure
      reader&.close
      writer&.close
    end

    it "retries a read that would block" do
      reader, = pipe_with([ { "type" => "result", "success" => true, "output" => "Ok" }, { "type" => "end", "code" => 0 } ])
      calls = 0
      allow(reader).to receive(:read_nonblock).and_wrap_original do |original, *args, **options|
        (calls += 1) == 1 ? :wait_readable : original.call(*args, **options)
      end
      job.send(:consume, reader)
      expect(calls).to be > 1
      expect(run.reload.status).to eq("completed")
    ensure
      reader&.close
    end

    it "leaves a run finished elsewhere untouched when the output ends" do
      run.update!(status: "completed")
      reader, = pipe_with([])
      job.send(:consume, reader)
      expect(run.reload).to have_attributes(status: "completed", error_code: nil, ended_at: nil)
    ensure
      reader&.close
    end
  end

  describe "runtime events" do
    it "clears the streamed text on a reset" do
      run.update!(output: "Made-up turn")
      job.send(:handle, { "type" => "reset" })
      expect(run.reload.output).to eq("")
    end

    it "keeps the highest token count, capped at twice the reservation" do
      run.update!(tokens_used: 10, tokens_reserved: 100)
      job.send(:handle, { "type" => "usage", "tokens" => 5 })
      expect(run.reload.tokens_used).to eq(10)
      job.send(:handle, { "type" => "usage", "tokens" => 999 })
      expect(run.reload.tokens_used).to eq(200)
    end

    it "answers browser session calls and refuses them outside a task" do
      stdin = StringIO.new
      job.instance_variable_set(:@stdin, stdin)
      job.send(:handle, { "type" => "rails_session", "id" => "s-1", "op" => "site_secret", "args" => {} })
      expect(JSON.parse(stdin.string.lines.last)).to include("type" => "rails_session_result", "id" => "s-1",
                                                              "result" => { "error" => "Unknown session call." })
      run.update!(kind: "task")
      job.send(:handle, { "type" => "rails_session", "id" => "s-2", "op" => "site_secret", "args" => { "domain" => "none.example" } })
      expect(JSON.parse(stdin.string.lines.last)["result"]).to eq("error" => "unknown_site")
    end
  end
end
