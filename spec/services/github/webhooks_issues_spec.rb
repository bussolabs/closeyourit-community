# frozen_string_literal: true

require "rails_helper"

# CYRA-1055 — issues of a hooked repository become tickets and follow their changes.
RSpec.describe Github::Webhooks::Issues do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let!(:open_status) { create(:ticket_status, organization:, position: 0) }
  let!(:priority) { create(:ticket_priority, organization:, code: "medium") }
  let!(:repository) do
    create(:github_repository, project:, issue_sync: :all_issues,
                               installation: create(:github_installation, organization:))
  end

  def issue(overrides = {})
    {
      "number" => 7, "id" => 77, "node_id" => "I_7", "title" => "Login rotto", "body" => "Non riesco a entrare",
      "state" => "open", "html_url" => "https://github.com/bussolabs/app/issues/7",
      "user" => { "login" => "alice" }, "labels" => [], "assignees" => [], "updated_at" => "2026-11-05T10:00:00Z"
    }.merge(overrides)
  end

  def payload(action:, issue: self.issue, sender: "alice")
    {
      "action" => action, "issue" => issue, "sender" => { "login" => sender },
      "repository" => { "id" => repository.repo_id },
      "installation" => { "id" => repository.installation.installation_id }
    }
  end

  def link = repository.issues.find_by(number: 7)

  describe "a new issue" do
    it "becomes a ticket with the same title and text, signed GitHub with the writer's GitHub name beside it" do
      described_class.call(payload: payload(action: "opened"))

      ticket = link.ticket
      expect(ticket.title).to eq("Login rotto")
      expect(ticket.description).to eq("Non riesco a entrare")
      expect(ticket.reporter.name).to eq("GitHub")
      expect(ticket.reporter).to be_service
      expect(link.author_login).to eq("alice")
      expect(ticket.events.find_by(action: "github_issue_imported").data["login"]).to eq("alice")
    end

    it "does nothing, and raises nothing, when the project keeps the sync off" do
      repository.update!(issue_sync: :off)

      expect { described_class.call(payload: payload(action: "opened")) }.not_to change(Ticketing::Ticket, :count)
    end

    it "ignores the delivery caused by this app itself" do
      allow(Settings::Integrations).to receive(:value).and_call_original
      allow(Settings::Integrations).to receive(:value).with(:gh_app_slug).and_return("closeyourit")

      expect { described_class.call(payload: payload(action: "opened", sender: "closeyourit[bot]")) }
        .not_to change(Ticketing::Ticket, :count)
    end

    it "with board issues only, an issue outside the board makes no ticket" do
      repository.update!(issue_sync: :board_issues, board_node_id: "PVT_1", board_status_field_id: "F_1")
      allow(Github::Client).to receive(:new).and_return(instance_double(Github::Client, issue_board_items: []))

      expect { described_class.call(payload: payload(action: "opened")) }.not_to change(Ticketing::Ticket, :count)
    end

    it "leaves the ticket unassigned when nobody wrote that GitHub name, and says who it was" do
      described_class.call(payload: payload(action: "opened", issue: issue("assignees" => [ { "login" => "ghost" } ])))

      expect(link.ticket.assignee).to be_nil
      expect(link.ticket.events.find_by(action: "github_assignee_unknown").data["login"]).to eq("ghost")
    end

    it "assigns the member who wrote that GitHub name in the profile" do
      member = create(:account, github_login: "Mario-Rossi")
      create(:membership, account: member, organization:)

      described_class.call(payload: payload(action: "opened", issue: issue("assignees" => [ { "login" => "mario-rossi" } ])))

      expect(link.ticket.assignee).to eq(member)
    end

    it "turns a mapped label into the ticket type" do
      repository.update!(label_kinds: { "Bug" => "bug" })

      described_class.call(payload: payload(action: "opened", issue: issue("labels" => [ { "name" => "bug" } ])))

      expect(link.ticket).to be_kind_bug
    end
  end

  describe "a linked issue" do
    before { described_class.call(payload: payload(action: "opened")) }

    it "changes the ticket's title, and the history says so" do
      described_class.call(payload: payload(action: "edited", issue: issue("title" => "Login rotto su Safari",
                                                                          "updated_at" => "2026-11-05T11:00:00Z")))

      expect(link.ticket.reload.title).to eq("Login rotto su Safari")
      expect(link.ticket.events.where(action: "updated")).to exist
    end

    it "closing it moves the ticket to the first done status" do
      done = create(:ticket_status, :done, organization:)

      described_class.call(payload: payload(action: "closed", issue: issue("state" => "closed",
                                                                          "updated_at" => "2026-11-05T11:00:00Z")))

      expect(link.ticket.reload.status).to eq(done)
    end

    it "an older delivery changes nothing" do
      described_class.call(payload: payload(action: "edited", issue: issue("title" => "Vecchio titolo",
                                                                          "updated_at" => "2026-01-01T00:00:00Z")))

      expect(link.ticket.reload.title).to eq("Login rotto")
    end

    it "deleted on GitHub: the link breaks, the ticket stays" do
      ticket = link.ticket

      described_class.call(payload: payload(action: "deleted"))

      expect(link).to be_nil
      expect(ticket.reload).to be_persisted
      expect(ticket.events.find_by!(action: "github_issue_unlinked").data["reason"]).to eq("deleted")
      expect(I18n.t("member.tickets.activity.github_issue_unlinked", locale: :en, number: 7)).not_to include("board")
    end
  end

  describe "deliveries that make no ticket" do
    it "a closed issue, an issue deleted before it had a ticket, a number that is not one" do
      described_class.call(payload: payload(action: "closed", issue: issue("state" => "closed")))
      described_class.call(payload: payload(action: "deleted"))
      described_class.call(payload: payload(action: "opened", issue: issue("number" => "sette")))

      expect(repository.issues).to be_empty
    end

    it "with board issues only, an issue GitHub sent without its node id" do
      repository.update!(issue_sync: :board_issues, board_node_id: "PVT_1", board_status_field_id: "F_1")

      expect { described_class.call(payload: payload(action: "opened", issue: issue("node_id" => nil))) }
        .not_to change(Ticketing::Ticket, :count)
    end
  end

  it "with board issues only, an issue on the board becomes a ticket with its card" do
    repository.update!(issue_sync: :board_issues, board_node_id: "PVT_1", board_status_field_id: "F_1")
    card = { item_id: "PVTI_7", board_id: "PVT_1", issue_node_id: "I_7", number: 7, repo_id: repository.repo_id, options: {} }
    other = card.merge(item_id: "PVTI_8", board_id: "PVT_OTHER")
    allow(Github::Client).to receive(:new)
      .and_return(instance_double(Github::Client, issue_board_items: [ other, card ], issue_comments: []))

    described_class.call(payload: payload(action: "opened"))

    expect(link).to have_attributes(board_item_node_id: "PVTI_7")
  end
end
