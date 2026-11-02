# frozen_string_literal: true

require "rails_helper"

# CYRA-1138 — the live page of an automator attempt: what the agent touched, its changes in review
# style, its latest steps. Behind agents.view, and only for tickets the viewer can see.
RSpec.describe "Member::Agents::LiveSessions", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }
  let(:host) { create(:agent_host, organization:, hostname: "mac-live") }
  let(:ticket) { create(:ticket, organization:, title: "Filter tickets by status") }
  let(:workflow) { ticket.agent_workflow || create(:agent_workflow, organization:, ticket:) }
  let(:attempt) { create(:agent_attempt, workflow:, organization:, host:, phase: "autopilot", status: :running) }
  let(:hunk) { { "old_start" => 3, "old_lines" => 1, "new_start" => 3, "new_lines" => 2, "lines" => [ " keep", "-old_line", "+new_line" ] } }

  before { create(:membership, account: owner, organization:, role: :owner) }

  def sign_in(who)
    post login_path, params: { email: who.email, password: "Secret123!" }
  end

  def step(seq, kind, payload, on: attempt)
    Agents::AttemptLiveEvent.create!(organization:, attempt: on, seq:, kind:, payload:,
                                     recorded_at: Time.utc(2026, 11, 2, 15, 0, seq), created_at: Time.current)
  end

  def change(path, hunks: nil)
    { "path" => path, "created" => false, "added" => 1, "removed" => 1, "hunks" => hunks }
  end

  def html = Capybara.string(response.body)

  describe "who can open it" do
    it "sends a visitor to the login" do
      get member_agents_live_session_path(attempt)

      expect(response).to redirect_to(login_path)
    end

    it "turns away a member without agents.view" do
      member = create(:account)
      create(:membership, account: member, organization:, role: :member)
      sign_in(member)

      get member_agents_live_session_path(attempt)

      expect(response).to redirect_to(root_path)
    end

    it "answers 404 for a ticket the viewer cannot see, and keeps it out of the list" do
      viewer = create(:account)
      create(:membership, account: viewer, organization:)
      create(:account_permission, account: viewer, organization:, permission_key: "agents.view", effect: :allow)
      attempt
      sign_in(viewer)

      get member_agents_live_session_path(attempt)
      expect(response).to have_http_status(:not_found)

      get member_agents_live_sessions_path
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("Filter tickets by status")
      expect(html).to have_css("[data-test='automator-live-empty']")
    end

    it "answers 404 for an attempt of another organization" do
      elsewhere = create(:organization)
      other = create(:agent_attempt, organization: elsewhere, host: create(:agent_host, organization: elsewhere),
                                     workflow: create(:agent_workflow, organization: elsewhere))
      sign_in(owner)

      get member_agents_live_session_path(other)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "the way in" do
    before { sign_in(owner) }

    it "opens from the machine's running work and from the menu" do
      host.update!(active_runs: [ { "ticket" => ticket.code } ])
      attempt

      get member_agent_path(host)

      expect(html).to have_link(href: member_agents_live_session_path(attempt))
      expect(html).to have_css("[data-test='member-nav-automator-live']")
    end
  end

  describe "the list" do
    before { sign_in(owner) }

    it "opens the most recent session at work" do
      attempt
      get member_agents_live_sessions_path

      expect(response).to redirect_to(member_agents_live_session_path(attempt))
    end

    it "says there is nothing at work yet" do
      get member_agents_live_sessions_path

      expect(html).to have_css("[data-test='automator-live-empty']")
    end
  end

  describe "a session" do
    before { sign_in(owner) }

    it "frames the page like Coworkers, with the sessions at work in its own sidebar" do
      get member_agents_live_session_path(attempt)

      expect(html).to have_css("[data-test='automator-live-sidebar']", text: ticket.code)
      expect(html).to have_css("[data-test='automator-live-header']", text: "Filter tickets by status")
      expect(html).to have_css("[data-test='automator-live-header']", text: "mac-live")
      expect(html).to have_css("turbo-frame#automator-live")
      expect(html).to have_css("[data-controller~='live-frame'][data-live-frame-frame-value='automator-live']")
    end

    it "follows the last file changed and shows its changes in review style" do
      ticket.project.update!(automator_live_code_enabled: true)
      step(1, "file_read", { "path" => "README.md" })
      step(2, "file_change", change("app/models/ticket.rb", hunks: [ hunk ]))

      get member_agents_live_session_path(attempt)

      expect(html).to have_css("[data-test='automator-live-file'][aria-current='true'] [title='app/models/ticket.rb']")
      expect(html).to have_css("[data-test='automator-live-line-removed'] del", text: "old_line")
      expect(html).to have_css("[data-test='automator-live-line-added']", text: "new_line")
      expect(html).to have_css("[data-test='automator-live-view-switch']")
    end

    it "shows another file when asked, with a way back to following the agent" do
      ticket.project.update!(automator_live_code_enabled: true)
      step(1, "file_change", change("README.md", hunks: [ hunk ]))
      step(2, "file_change", change("app/models/ticket.rb", hunks: [ hunk ]))

      get member_agents_live_session_path(attempt, file: "README.md")

      expect(html).to have_css("[data-test='automator-live-file'][aria-current='true'] [title='README.md']")
      expect(html).to have_css("[data-test='automator-live-follow']")
    end

    it "shows only names and counts when the project keeps the code on the machine" do
      step(1, "file_change", change("app/models/ticket.rb", hunks: [ hunk ]))

      get member_agents_live_session_path(attempt)

      expect(html).to have_css("[data-test='automator-live-file'] [title='app/models/ticket.rb']")
      expect(html).to have_css("[data-test='automator-live-code-off']")
      expect(html).to have_no_css("[data-test='automator-live-line-added']")
      expect(html).to have_no_css("[data-test='automator-live-view-switch']")
    end

    it "shows only names and counts when the viewer picks files only" do
      ticket.project.update!(automator_live_code_enabled: true)
      step(1, "file_change", change("app/models/ticket.rb", hunks: [ hunk ]))

      get member_agents_live_session_path(attempt, view: "files")

      expect(html).to have_no_css("[data-test='automator-live-line-added']")
      expect(html).to have_css("[data-test='automator-live-view-switch']")
    end

    it "lists the latest steps, newest first" do
      step(1, "search", { "pattern" => "def call" })
      step(2, "command", { "command" => "bin/rspec spec/models" })

      get member_agents_live_session_path(attempt)

      expect(html.all("[data-test='automator-live-step']").map(&:text).map(&:squish))
        .to match([ a_string_including("bin/rspec spec/models"), a_string_including("def call") ])
    end

    it "tells the viewer nothing happened yet" do
      get member_agents_live_session_path(attempt)

      expect(html).to have_css("[data-test='automator-live-no-steps']")
    end

    it "answers the frame alone when the page reloads it" do
      step(1, "file_read", { "path" => "README.md" })

      get member_agents_live_session_path(attempt), headers: { "Turbo-Frame" => "automator-live" }

      expect(html).to have_css("turbo-frame#automator-live")
      expect(html).to have_no_css("[data-test='automator-live-sidebar']")
    end

    it "ticks the time at work from the real start and names the engine in the agent's colour" do
      attempt.update_columns(started_at: 3.minutes.ago - 42.seconds)

      get member_agents_live_session_path(attempt)

      timer = html.find("[data-test='automator-live-elapsed']")
      expect(timer.text).to eq("3:42")
      expect(timer["data-automator-live-elapsed-since-value"]).to eq(attempt.reload.started_at.iso8601)
      expect(html.find("[data-test='automator-live-engine']").text).to eq("Claude")
      expect(html).to have_css("[data-test='automator-live-session'] [data-color='violet']")
    end

    it "lets the new lines of a change that just arrived enter in turn, and tags the last one with the agent" do
      ticket.project.update!(automator_live_code_enabled: true)
      fresh = hunk.merge("lines" => [ "-old_line", "+first_new", "+second_new" ])
      Agents::AttemptLiveEvent.create!(organization:, attempt:, seq: 1, kind: "file_change", payload: change("app/models/ticket.rb", hunks: [ fresh ]),
                                       recorded_at: 2.seconds.ago, created_at: Time.current)

      get member_agents_live_session_path(attempt)

      added = html.all("[data-test='automator-live-line-added']")
      expect(added.map { it["style"] }).to eq([ "animation-delay: 0ms", "animation-delay: 90ms" ])
      expect(added.last).to have_css("[data-test='automator-live-cursor']", text: "Claude · #{ticket.code}")
      expect(html.all("[data-test='automator-live-cursor']").size).to eq(1)
    end

    it "shows an older change still, with the agent's tag but no entrance" do
      ticket.project.update!(automator_live_code_enabled: true)
      step(1, "file_change", change("app/models/ticket.rb", hunks: [ hunk ]))

      get member_agents_live_session_path(attempt)

      expect(html.find("[data-test='automator-live-line-added']")["style"]).to be_nil
      expect(html).to have_css("[data-test='automator-live-cursor']")
    end

    it "listens to the whole project, so a step of another agent refreshes this page" do
      get member_agents_live_session_path(attempt)

      expect(response.body).to include(Realtime::Streams.automator_live_project(organization_id: organization.id, project_id: ticket.project_id)
                                         .then { Turbo::StreamsChannel.signed_stream_name(it) })
    end

    it "can be reopened when the work is over" do
      attempt.update_columns(status: Agents::Attempt.statuses[:approved], finished_at: Time.current)
      step(1, "file_read", { "path" => "README.md" })

      get member_agents_live_session_path(attempt)

      expect(response).to have_http_status(:ok)
      expect(html).to have_css("[data-test='automator-live-file'] [title='README.md']")
    end
  end

  describe "the whole project tree from GitHub" do
    let(:paths) { %w[README.md app/models/agents/attempt.rb app/models/agents/workflow.rb config/routes.rb] }

    before do
      tree = Agents::LiveEvents::ProjectTree::Result.new(paths:, partial: false)
      allow(Agents::LiveEvents::ProjectTree).to receive(:call).and_return(tree)
      step(1, "file_change", change("app/models/agents/attempt.rb", hunks: [ hunk ]))
      sign_in(owner)
    end

    it "shows the untouched files too, opens the folders the agent works in and closes the others" do
      get member_agents_live_session_path(attempt)

      expect(html).to have_css("[data-test='automator-live-tree-file']", text: "README.md")
      expect(html).to have_css("[data-test='automator-live-tree-file']", text: "workflow.rb")
      expect(html).to have_css("[data-test='automator-live-file']", text: "attempt.rb")
      expect(html).to have_css("details[data-dir='config']:not([open])")
      expect(html).not_to have_css("[data-test='automator-live-tree-file']", text: "routes.rb")
      expect(html).to have_css("turbo-frame[loading='lazy'][src*='dir=config']", visible: :all)
    end

    it "adds a file the agent created that main does not have yet" do
      step(2, "file_change", change("app/models/agents/new_thing.rb"))

      get member_agents_live_session_path(attempt)

      expect(html).to have_css("[data-test='automator-live-file']", text: "new_thing.rb")
    end

    it "loads one closed folder on demand" do
      get tree_member_agents_live_session_path(attempt, dir: "config")

      expect(response).to have_http_status(:ok)
      expect(html).to have_css("turbo-frame#automator-live-tree-#{"config".unpack1("H*")}[target='_top'] [data-test='automator-live-tree-file']", text: "routes.rb")
    end

    it "says the list is partial when GitHub cut it" do
      allow(Agents::LiveEvents::ProjectTree).to receive(:call)
        .and_return(Agents::LiveEvents::ProjectTree::Result.new(paths:, partial: true))

      get member_agents_live_session_path(attempt)

      expect(html).to have_css("[data-test='automator-live-tree-partial']")
    end

    it "falls back to the touched files when the project has no tree" do
      allow(Agents::LiveEvents::ProjectTree).to receive(:call).and_return(nil)

      get member_agents_live_session_path(attempt)

      expect(html).to have_css("[data-test='automator-live-file']", text: "attempt.rb")
      expect(html).not_to have_css("[data-test='automator-live-tree-file']")
    end

    it "answers 404 for the folder of an attempt of another organization" do
      elsewhere = create(:organization)
      other = create(:agent_attempt, organization: elsewhere, host: create(:agent_host, organization: elsewhere),
                                     workflow: create(:agent_workflow, organization: elsewhere))

      get tree_member_agents_live_session_path(other, dir: "config")

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "conflicts with another agent of the project" do
    let(:other_ticket) { create(:ticket, organization:, project: ticket.project, title: "Fix the CSV export") }
    let(:other) do
      other_workflow = other_ticket.agent_workflow || create(:agent_workflow, organization:, ticket: other_ticket)
      create(:agent_attempt, workflow: other_workflow, organization:, host:, phase: "autopilot", status: :running, started_at: 1.minute.ago)
    end

    before { sign_in(owner) }

    def changed(on, path, old_start)
      step(1, "file_change", change(path, hunks: [ hunk.merge("old_start" => old_start) ]), on:)
    end

    it "warns in red at the bottom right when the other agent changes the same lines, with a way to open the file and pause" do
      changed(attempt, "app/models/ticket.rb", 10)
      changed(other, "app/models/ticket.rb", 10)

      get member_agents_live_session_path(attempt)

      notice = html.find("[data-test='automator-live-conflicts'] [data-test='automator-live-conflict']")
      expect(notice["data-level"]).to eq("lines")
      expect(notice.text).to include(other_ticket.code, "app/models/ticket.rb")
      expect(notice).to have_link(href: member_agents_live_session_path(attempt, file: "app/models/ticket.rb"))
      expect(notice).to have_css("form[action='#{member_ticket_eligibility_path(other_ticket)}']")
    end

    it "stacks two warnings, the red one in front, with a counter" do
      changed(attempt, "app/models/ticket.rb", 10)
      changed(other, "app/models/ticket.rb", 10)
      step(2, "file_change", change("config/routes.rb", hunks: [ hunk.merge("old_start" => 3) ]))
      step(2, "file_change", change("config/routes.rb", hunks: [ hunk.merge("old_start" => 90) ]), on: other)

      get member_agents_live_session_path(attempt)

      expect(html.all("[data-test='automator-live-conflict']").map { it["data-level"] }).to eq(%w[lines file])
      expect(html).to have_css("[data-test='automator-live-conflicts-count']", text: "2")
    end

    it "warns in red from the line numbers alone when the project keeps the code on the machine (CYAU-299)" do
      ticket.project.update!(automator_live_code_enabled: false)
      changed(attempt, "app/models/ticket.rb", 10)
      changed(other, "app/models/ticket.rb", 10)

      get member_agents_live_session_path(attempt)

      expect(html.find("[data-test='automator-live-conflict']")["data-level"]).to eq("lines")
    end

    it "says nothing about agents of another project" do
      attempt
      elsewhere_ticket = create(:ticket, organization:, project: create(:project, organization:), title: "Elsewhere")
      elsewhere_workflow = elsewhere_ticket.agent_workflow || create(:agent_workflow, organization:, ticket: elsewhere_ticket)
      elsewhere = create(:agent_attempt, workflow: elsewhere_workflow, organization:, host:, phase: "autopilot", status: :running)
      changed(attempt, "app/models/ticket.rb", 10)
      changed(elsewhere, "app/models/ticket.rb", 10)

      get member_agents_live_session_path(attempt)

      expect(html).to have_no_css("[data-test='automator-live-conflicts']")
    end
  end
end
