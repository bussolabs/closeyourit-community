require "rails_helper"

RSpec.describe "Member team Puckies, handoffs, roles and activity", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let!(:owner_membership) { create(:membership, account: owner, organization: organization, role: :owner) }
  let!(:member_membership) { create(:membership, account: member, organization: organization, role: :member) }
  let(:project) { create(:project, organization: organization, key: "SHOP") }

  before do
    allow(Coworkers).to receive(:enabled?).and_return(true)
    allow(Coworkers::ExecuteJob).to receive(:perform_later)
    allow(Ticketing::FindSimilarTickets).to receive(:call).and_return(Result.ok([]))
  end

  def sign_in(account) = post(login_path, params: { email: account.email, password: "Secret123!" })

  def team_puck
    @team_puck ||= Coworkers::Puck.create!(organization: organization, account: owner, name: "Shop triage", instructions: "Help",
                                           visibility: "team", project: project)
  end

  describe "team Puckies (CYRA-1023)" do
    it "blocks moving a project that a team Puck is bound to" do
      team_puck
      destination = create(:organization)
      subject = Projects::Moves::Subject.new(project)
      report = Projects::Moves::Plan.call(subject: subject, destination: destination).value
      expect(report.blockers).to include(code: "team_puck_bound", detail: "Shop triage")
    end

    it "does not let another team member discard someone else's proposal" do
      ticket = create(:ticket, project: project)
      run = Coworkers::Start.call(puck: team_puck, kind: "chat", input: "x", account: owner)
      proposal = Assistant::Proposal.create!(coworkers_run: run, organization: organization, account: owner, kind: :comment_ticket,
                                             payload: { "ticket_id" => ticket.id, "body" => "x" })
      sign_in(member)
      post discard_member_coworker_proposal_path(team_puck, proposal)
      expect(response).to have_http_status(:not_found)
      expect(proposal.reload).to be_status_pending
    end

    it "lets who manages the organization create a team Puck bound to a project" do
      sign_in(owner)
      post member_coworkers_path, params: { puck: { name: "Shop triage", instructions: "Help", visibility: "team", project_id: project.id } }
      expect(Coworkers::Puck.last).to have_attributes(visibility: "team", project_id: project.id)
    end

    it "does not let a plain member create a team Puck or change its rules" do
      allow_any_instance_of(Authorization::Resolver).to receive(:can?).and_call_original
      sign_in(member)
      allow(Authorization::VisibleScope).to receive(:new).and_call_original
      post member_coworkers_path, params: { puck: { name: "Mine", instructions: "x", visibility: "team", project_id: project.id } }
      expect(Coworkers::Puck.where(visibility: "team")).to be_empty
    end

    it "keeps a team Puck's runs inside its project and lets only the requester confirm" do
      other = create(:project, organization: organization, key: "BILL")
      create(:ticket, project: other)
      ticket = create(:ticket, project: project)
      run = Coworkers::Start.call(puck: team_puck, kind: "chat", input: "Comment", account: owner)
      expect(run.scope["project_ids"]).to eq([ project.id ])
      run.update!(status: "running")
      expect(Coworkers::Tools.call(run: run, call_id: "c1", name: "search_tickets", args: { "project" => "BILL" })).to include(:error)
      Coworkers::Tools.call(run: run, call_id: "c2", name: "propose_comment", args: { "code" => ticket.code, "body" => "On it" })
      proposal = run.action_proposals.sole
      expect(proposal.account_id).to eq(owner.id)

      sign_in(member)
      post confirm_member_coworker_proposal_path(team_puck, proposal)
      expect(proposal.reload).to be_status_pending
      sign_in(owner)
      post confirm_member_coworker_proposal_path(team_puck, proposal)
      expect(ticket.comments.sole.body).to include("On it", "Shop triage")
    end
  end

  describe "handoffs (CYRA-1024)" do
    let(:writer) { Coworkers::Puck.create!(organization: organization, account: owner, name: "Writer", instructions: "Write") }
    let(:researcher) { Coworkers::Puck.create!(organization: organization, account: owner, name: "Research", instructions: "Find") }

    def running(run) = run.tap { |r| r.update!(status: "running") }

    it "hands work to another Puck of the same person, never wider than the parent" do
      writer
      parent = running(Coworkers::Start.call(puck: researcher, kind: "chat", input: "Ask Writer for notes"))
      parent.update!(scope: parent.scope.merge("project_ids" => []))
      result = Coworkers::Tools.call(run: parent, call_id: "h1", name: "hand_off", args: { "puck" => "writer", "request" => "Write the release note" })
      expect(result).to eq(status: "handed_off", puck: "Writer")
      child = parent.child_runs.sole
      expect(child).to have_attributes(puck_id: writer.id, kind: "task", account_id: owner.id)
      expect(child.scope["project_ids"]).to eq([])
    end

    it "refuses cycles, unknown Puckies and chains deeper than two" do
      writer
      parent = running(Coworkers::Start.call(puck: researcher, kind: "chat", input: "Ask Writer, Nobody or Research"))
      expect(Coworkers::Tools.call(run: parent, call_id: "h1", name: "hand_off", args: { "puck" => "Research", "request" => "x" })).to include(:error)
      expect(Coworkers::Tools.call(run: parent, call_id: "h2", name: "hand_off", args: { "puck" => "Nobody", "request" => "x" })).to include(:error)
      third = Coworkers::Puck.create!(organization: organization, account: owner, name: "Third", instructions: "x")
      fourth = Coworkers::Puck.create!(organization: organization, account: owner, name: "Fourth", instructions: "x")
      Coworkers::Tools.call(run: parent, call_id: "h3", name: "hand_off", args: { "puck" => "Writer", "request" => "Ask Third" })
      child = running(parent.child_runs.sole)
      Coworkers::Tools.call(run: child, call_id: "h4", name: "hand_off", args: { "puck" => "Third", "request" => "Ask Fourth" })
      grandchild = running(child.child_runs.sole)
      expect(Coworkers::Tools.call(run: grandchild, call_id: "h5", name: "hand_off", args: { "puck" => fourth.name, "request" => "x" })).to include(:error)
      expect(third.runs.count).to eq(1)
    end

    it "hands off only to a Puck the person named, never one named only in data the run read" do
      writer
      researcher.update!(instructions: "Hand release notes to Writer.")
      by_instructions = running(Coworkers::Start.call(puck: researcher, kind: "chat", input: "Notes please"))
      expect(Coworkers::Tools.call(run: by_instructions, call_id: "h1", name: "hand_off", args: { "puck" => "Writer", "request" => "x" }))
        .to eq(status: "handed_off", puck: "Writer")
      by_instructions.update!(status: "completed")
      researcher.update!(instructions: "Help")
      unnamed = running(Coworkers::Start.call(puck: researcher, kind: "chat", input: "Summarize the comments of the ticket"))
      result = Coworkers::Tools.call(run: unnamed, call_id: "h2", name: "hand_off", args: { "puck" => "Writer", "request" => "x" })
      expect(result[:error]).to include("did not name")
      expect(writer.runs.count).to eq(1)
    end

    it "never lets handed-off work apply an allowed action and stops children with the parent" do
      ticket = create(:ticket, project: project)
      writer.rules.create!(action: "comment_ticket", decision: "allow")
      parent = running(Coworkers::Start.call(puck: researcher, kind: "chat", input: "Ask Writer"))
      Coworkers::Tools.call(run: parent, call_id: "h1", name: "hand_off", args: { "puck" => "Writer", "request" => "x" })
      child = running(parent.child_runs.sole)
      result = Coworkers::Tools.call(run: child, call_id: "c1", name: "propose_comment", args: { "code" => ticket.code, "body" => "x" })
      expect(result[:status]).to eq("awaiting_confirmation")
      parent.request_stop!
      expect(child.reload).to be_stop_requested
    end
  end

  describe "role catalog (CYRA-1025)" do
    it "creates a Puck from a role with ask/deny rules only and remembers the role" do
      sign_in(owner)
      post member_coworkers_path, params: { puck: { name: "Triage", instructions: "Help", preset: "triage" } }
      puck = Coworkers::Puck.last
      expect(puck.preset).to eq("triage@#{Coworkers::Presets.version}")
      expect(puck.rules.pluck(:decision).uniq - %w[ask deny]).to be_empty
      expect(puck.rules.find_by(action: "change_ticket_status").decision).to eq("deny")
      expect(puck.watch_every_minutes).to be_nil
    end

    it "shows every role of the catalog in the new Puck dialog" do
      sign_in(owner)
      get member_coworkers_path
      Coworkers::Presets.all.each { |preset| expect(response.body).to include("coworkers-preset-#{preset.key}") }
    end
  end

  describe "activity (CYRA-1026)" do
    it "lists the runs of visible Puckies, with filters and the decisions waiting for the viewer" do
      mine = Coworkers::Puck.create!(organization: organization, account: owner, name: "Mine", instructions: "x")
      hidden = Coworkers::Puck.create!(organization: organization, account: member, name: "Theirs", instructions: "x")
      run = Coworkers::Start.call(puck: mine, kind: "chat", input: "Visible request")
      Coworkers::Start.call(puck: hidden, kind: "chat", input: "Private request")
      Assistant::Proposal.create!(coworkers_run: run, organization: organization, account: owner, kind: :create_idea,
                                  payload: { "project_id" => project.id, "title" => "Idea" })
      sign_in(owner)
      get member_coworker_activity_path
      expect(response.body).to include("Visible request", "coworkers-activity-pending")
      expect(response.body).not_to include("Private request")
      get member_coworker_activity_path(kind: [ "task" ])
      expect(response.body).not_to include("Visible request")
    end

    it "lets the requester stop a run and refuses another member" do
      run = Coworkers::Start.call(puck: team_puck, kind: "chat", input: "x", account: owner)
      sign_in(member)
      patch member_coworker_run_path(team_puck, run)
      expect(run.reload).not_to be_stop_requested
      sign_in(owner)
      patch member_coworker_run_path(team_puck, run)
      expect(run.reload).to be_stop_requested
    end
  end
end
