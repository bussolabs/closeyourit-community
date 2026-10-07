require "rails_helper"

RSpec.describe "Puck hands a bug to the automation (CYRA-1028)" do
  let(:organization) { create(:organization) }
  let(:account) { create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :owner) } }
  let(:project) { create(:project, organization: organization, key: "SHOP") }
  let!(:ticket) { create(:ticket, project: project, title: "Checkout fails", agent_eligibility: :blocked) }
  let(:puck) { Coworkers::Puck.create!(organization: organization, account: account, name: "Bug repro", instructions: "Help") }
  let(:run) { Coworkers::Start.call(puck: puck, kind: "chat", input: "Fix it").tap { |r| r.update!(status: "running") } }

  before do
    allow(Coworkers).to receive(:enabled?).and_return(true)
    allow(Coworkers::ExecuteJob).to receive(:perform_later)
  end

  def call(name, args) = Coworkers::Tools.call(run: run, call_id: SecureRandom.uuid, name: name, args: args)

  it "always waits for a person, even when the rule would allow it" do
    puck.rules.create!(action: "start_agent_work", decision: "allow")
    result = call("propose_agent_fix", { "code" => ticket.code, "note" => "Reproduced on Safari" })
    expect(result[:status]).to eq("awaiting_confirmation")
    expect(ticket.reload).to be_agent_eligibility_blocked
  end

  it "lets the automation work the ticket once the person confirms" do
    call("propose_agent_fix", { "code" => ticket.code })
    outcome = Assistant::Proposals::Confirm.call(proposal: run.action_proposals.sole, account: account, organization: organization)
    expect(outcome).to be_ok
    expect(ticket.reload).to have_attributes(agent_eligibility: "allowed", agent_eligibility_source: "human")
  end

  it "puts the proof video the Puck recorded on the ticket" do
    run.video.attach(io: StringIO.new("\x1A\x45\xDF\xA3webm".b), filename: "proof.webm", content_type: "video/webm")
    call("propose_agent_fix", { "code" => ticket.code })
    allow(Ticketing::AttachToTicket).to receive(:call).and_call_original
    Assistant::Proposals::Confirm.call(proposal: run.action_proposals.sole, account: account, organization: organization)
    expect(Ticketing::AttachToTicket).to have_received(:call).with(hash_including(ticket: ticket))
  end

  it "reports the automation phase and the pull requests of the ticket" do
    repository = create(:github_repository, project: project)
    Github::PullRequest.create!(repository: repository, ticket: ticket, number: 7, title: "Fix checkout", html_url: "https://github.com/x/y/pull/7")
    status = call("agent_fix_status", { "code" => ticket.code })
    expect(status).to include(ticket: ticket.code, automation: "blocked")
    expect(status[:pull_requests]).to eq([ { number: 7, state: "open", url: "https://github.com/x/y/pull/7", merged: false } ])
  end
end
