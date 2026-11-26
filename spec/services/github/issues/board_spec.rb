# frozen_string_literal: true

require "rails_helper"

# CYRA-1055 — a card moved on the organization board moves its ticket.
RSpec.describe Github::Issues::Board do
  let(:link) { create(:github_issue, board_item_node_id: "PVTI_1", board_option_id: "OPT_TODO") }
  let(:repository) { link.repository }
  let(:ticket) { link.ticket }
  let(:in_progress) { create(:ticket_status, organization: ticket.project.organization, category: :in_progress) }
  let(:client) { instance_double(Github::Client) }

  before do
    repository.update!(board_node_id: "PVT_1", board_status_field_id: "F_1",
                       board_columns: { "OPT_TODO" => ticket.status_id, "OPT_DOING" => in_progress.id })
  end

  def item(option)
    { item_id: "PVTI_1", board_id: "PVT_1", issue_node_id: link.node_id, number: link.number,
      repo_id: repository.repo_id, options: { "F_1" => option } }
  end

  def move(action: "edited", item: item("OPT_DOING"))
    described_class.call(installation: repository.installation, board_node_id: "PVT_1", item_node_id: "PVTI_1",
                         action:, item:, client:)
  end

  it "moving the card to In Progress gives the ticket the status mapped to that column" do
    move

    expect(ticket.reload.status).to eq(in_progress)
    expect(link.reload.board_option_id).to eq("OPT_DOING")
  end

  it "a move the ticket's prerequisites refuse stays written in its history" do
    create(:ticket_dependency, ticket:, blocker: create(:ticket, project: ticket.project))

    move

    expect(ticket.reload.status).not_to eq(in_progress)
    expect(ticket.events.find_by(action: "github_change_declined").data["fields"]).to eq(%w[status])
  end

  it "a card leaving the board breaks the link when the project takes board issues only; the ticket stays" do
    repository.update!(issue_sync: :board_issues)

    move(action: "deleted", item: nil)

    expect(Github::Issue.exists?(link.id)).to be(false)
    expect(ticket.reload.events.where(action: "github_issue_unlinked")).to exist
  end

  it "with every issue synced, a card leaving the board only forgets the card" do
    expect(move(action: "deleted", item: nil).value).to eq(link)

    expect(link.reload).to have_attributes(board_item_node_id: nil, board_option_id: nil)
  end

  it "a card that was never linked leaves without changing anything" do
    result = described_class.call(installation: repository.installation, board_node_id: "PVT_1", item_node_id: "PVTI_X",
                                  action: "archived", client:)

    expect(result.value).to be_nil
    expect(link.reload.board_item_node_id).to eq("PVTI_1")
  end

  it "a card moved to a column mapped to no status keeps the ticket where it is" do
    move(item: item("OPT_UNMAPPED"))

    expect(ticket.reload.status_id).to eq(repository.board_columns["OPT_TODO"])
    expect(link.reload.board_option_id).to eq("OPT_UNMAPPED")
  end

  it "ignores a board no project follows, and a card of another repository" do
    allow(client).to receive(:board_item).and_return(item("OPT_DOING").merge(repo_id: repository.repo_id + 1))

    expect(move(item: nil).value).to be_nil
    other_board = described_class.call(installation: repository.installation, board_node_id: "PVT_OTHER",
                                       item_node_id: "PVTI_1", action: "edited", client:)
    expect(other_board.value).to be_nil
    expect(ticket.reload.status).not_to eq(in_progress)
  end

  context "when a card enters the board" do
    let(:card) { item("OPT_TODO").merge(number: 4242, item_id: "PVTI_NEW") }

    def enter = described_class.call(installation: repository.installation, board_node_id: "PVT_1",
                                     item_node_id: "PVTI_NEW", action: "created", client:)

    before do
      allow(client).to receive(:board_item).and_return(card)
      allow(Github::Issues::Import).to receive(:call)
    end

    it "brings its issue in with its comments" do
      issue = { "number" => 4242, "state" => "open" }
      allow(client).to receive(:issue).and_return(issue)

      enter

      expect(Github::Issues::Import).to have_received(:call)
        .with(repository:, issue:, board_item: card, with_comments: true)
    end

    it "brings nothing when the issue is gone" do
      allow(client).to receive(:issue).and_return(nil)

      expect(enter.value).to be_nil
      expect(Github::Issues::Import).not_to have_received(:call)
    end
  end
end
