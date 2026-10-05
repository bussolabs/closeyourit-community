require "rails_helper"

RSpec.describe "Coworkers proposal approval" do
  let(:puck) { Coworkers::Puck.create!(account: create(:account), organization: create(:organization), name: "Researcher", instructions: "Cite sources") }
  let(:proposal) { { "objective" => "Research Cattolica", "activities" => "Read public sources", "limits" => "No writes" } }
  let(:chat) { puck.runs.create!(kind: "chat", input: "Research", status: "completed", proposed_task: proposal) }

  before { allow(Coworkers).to receive(:enabled?).and_return(true) }

  it "prepares without executing and starts only the stored proposal on approval" do
    expect { chat }.not_to have_enqueued_job
    task = Coworkers::Start.call(puck: puck, kind: "task", proposal_run: chat)
    expect(task).to have_attributes(kind: "task", proposal_run_id: chat.id)
    expect(task.input).to include(*proposal.values)
    expect(task.context["request"]).to eq(task.input)
  end

  it "reuses the same approved task after repeated approval, including after completion" do
    first = Coworkers::Start.call(puck: puck, kind: "task", proposal_run: chat)
    first.update!(status: "completed")
    expect {
      expect(Coworkers::Start.call(puck: puck, kind: "task", proposal_run: chat).id).to eq(first.id)
    }.not_to have_enqueued_job
    expect(chat.reload.approved_task.id).to eq(first.id)
    expect(puck.runs.where(kind: "task").count).to eq(1)
  end

  it "supersedes an unapproved proposal as soon as discussion resumes" do
    chat
    Coworkers::Start.call(puck: puck, kind: "chat", input: "Only research museums")
    expect(chat.reload.proposal_superseded).to be(true)
    expect { Coworkers::Start.call(puck: puck, kind: "task", proposal_run: chat) }.to raise_error(Coworkers::Start::InvalidProposal)
  end

  it "rejects unfinished, failed and stopped proposal runs" do
    %w[queued running failed stopped interrupted].each do |status|
      chat.update!(status: status)
      expect { Coworkers::Start.call(puck: puck, kind: "task", proposal_run: chat) }.to raise_error(Coworkers::Start::InvalidProposal)
    end
  end

  it "rejects malformed proposal fields" do
    [ nil, [], { "objective" => "Only one field" }, proposal.merge("limits" => "x" * 2001) ].each do |value|
      chat.proposed_task = value
      expect(chat).not_to be_valid
      expect(chat.errors[:proposed_task]).to be_present
    end
  end

  it "binds approval to the same Puck" do
    other = Coworkers::Puck.create!(account: puck.account, organization: puck.organization, name: "Other", instructions: "Read")
    expect { Coworkers::Start.call(puck: other, kind: "task", proposal_run: chat) }.to raise_error(ActiveRecord::RecordNotFound)
  end
end
