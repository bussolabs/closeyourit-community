require "rails_helper"

RSpec.describe Coworkers::ExecuteJob do
  let(:puck) { Coworkers::Puck.create!(account: create(:account), organization: create(:organization), name: "Researcher", instructions: "Cite sources") }
  let(:run) { puck.runs.create!(kind: "chat", input: "Hello") }

  before { allow(Coworkers).to receive(:enabled?).and_return(true) }

  it "does not launch stopped queued work" do
    run.update!(stop_requested: true)
    described_class.perform_now(run.id)
    expect(run.reload.status).to eq("stopped")
  end

  it "never replays a completed run when a job is delivered twice" do
    run.update!(status: "completed", output: "Existing answer")
    described_class.perform_now(run.id)
    expect(run.reload.output).to eq("Existing answer")
    expect(run.started_at).to be_nil
  end

  it "keeps a response failed when research has no successful evidence" do
    run.update!(kind: "task", status: "running")
    job = described_class.new
    job.instance_variable_set(:@run, run)
    job.send(:handle, { "type" => "result", "success" => true, "output" => "Unsupported claim" })
    job.send(:handle, { "type" => "end", "code" => 0 })
    expect(run.reload.status).to eq("failed")
    expect(run.output).to eq("Unsupported claim")
  end

  it "keeps the last valid partial output when the runtime exceeds the output limit" do
    run.update!(output: "Saved partial answer")
    job = described_class.new
    allow(job).to receive(:execute) do
      job.send(:handle, { "type" => "delta", "text" => "x" * 128001 })
    end
    expect { job.perform(run.id) }.to raise_error(ActiveRecord::RecordInvalid)
    expect(run.reload).to have_attributes(status: "failed", output: "Saved partial answer")
  end

  it "persists partial output and then the completed response" do
    run.update!(status: "running")
    job = described_class.new
    job.instance_variable_set(:@run, run)
    job.send(:handle, { "type" => "delta", "text" => "Part" })
    expect(run.reload.output).to eq("Part")
    job.send(:handle, { "type" => "result", "success" => true, "output" => "Complete answer" })
    job.send(:handle, { "type" => "end", "code" => 0 })
    expect(run.reload).to have_attributes(status: "completed", output: "Complete answer")
  end

  it "persists a proposal only after a successful chat without starting research" do
    job = described_class.new
    job.instance_variable_set(:@run, run)
    proposal = { "objective" => "Research museums", "activities" => "Read public sources", "limits" => "No writes" }
    expect {
      job.send(:handle, { "type" => "proposal", "proposal" => proposal })
      expect(run.reload.proposed_task).to eq({})
      job.send(:handle, { "type" => "result", "success" => true, "output" => "Review the proposal" })
      job.send(:handle, { "type" => "end", "code" => 0 })
    }.not_to have_enqueued_job
    expect(run.reload.proposed_task).to eq(proposal)
    expect(puck.runs.where(kind: "task")).to be_empty
  end

  it "discards proposals from failed or cancelled chats" do
    job = described_class.new
    job.instance_variable_set(:@run, run)
    job.send(:handle, { "type" => "proposal", "proposal" => { "objective" => "Research", "activities" => "Read", "limits" => "No writes" } })
    job.send(:handle, { "type" => "end", "code" => 1, "reason" => "stopped" })
    expect(run.reload.proposed_task).to eq({})
  end

  it "broadcasts linked task progress into both history and its originating chat" do
    chat = run
    task = puck.runs.create!(kind: "task", input: "Research", proposal_run: chat)
    allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
    task.publish
    expect(Turbo::StreamsChannel).to have_received(:broadcast_replace_to).with(anything, hash_including(target: "coworker_run_#{task.id}")).twice
    expect(Turbo::StreamsChannel).to have_received(:broadcast_replace_to).with(anything, hash_including(target: "coworker_run_#{chat.id}")).twice
  end

  # CYRA-914 D11: the runtime got AI_API_KEY and AI_BASE_URL straight from the environment, ignoring the
  # provider chosen in Valhalla.
  describe "AI settings of the runtime" do
    after { Ai::Configuration.reset! }

    def runtime_env = described_class.new.send(:runtime_env)

    it "passes the provider chosen in Valhalla" do
      Settings::Global.instance.update!(ai_provider: "custom", ai_api_key: "sk-valhalla",
                                        ai_base_url: "https://ai.example.test/v1", ai_chat_model: "m")
      Ai::Configuration.reset!

      expect(runtime_env).to include("AI_API_KEY" => "sk-valhalla", "AI_BASE_URL" => "https://ai.example.test/v1")
    end

    it "passes the environment values when Valhalla has none, as before" do
      expect(runtime_env).to include("AI_API_KEY" => ENV.fetch("AI_API_KEY"), "AI_BASE_URL" => ENV.fetch("AI_BASE_URL"))
    end
  end
  it "answers a runtime tool call on the runtime's input (CYRA-1009)" do
    run.update!(status: "running")
    job = described_class.new
    stdin = StringIO.new
    job.instance_variable_set(:@run, run)
    job.instance_variable_set(:@stdin, stdin)
    job.send(:handle, { "type" => "rails_tool", "id" => "call-1", "name" => "list_projects", "input" => {} })
    answer = JSON.parse(stdin.string)
    expect(answer).to include("type" => "rails_tool_result", "id" => "call-1")
    expect(answer["result"]).to be_a(Hash)
    job.send(:handle, { "type" => "rails_tool", "id" => "call-2", "name" => "drop_database", "input" => {} })
    expect(JSON.parse(stdin.string.lines.last)["result"]).to eq("error" => "Unknown tool call.")
  end
end
