# frozen_string_literal: true

require "rails_helper"

# CYRA-1055 — a linked ticket sends to its issue only what changed here since the last sync.
RSpec.describe Github::Issues::Push do
  let(:link) { create(:github_issue) }
  let(:repository) { link.repository }
  let(:ticket) { link.ticket }
  let(:organization) { ticket.project.organization }
  let(:client) { instance_double(Github::Client) }

  def response(overrides = {})
    { "number" => link.number, "title" => ticket.title, "body" => ticket.description.to_s, "state" => "open",
      "labels" => [], "assignees" => [], "updated_at" => Time.current.iso8601 }.merge(overrides)
  end

  it "sends only the field that changed" do
    ticket.update!(title: "Nuovo titolo")
    allow(client).to receive(:update_issue).and_return(response("title" => "Nuovo titolo"))

    described_class.call(ticket:, client:)

    expect(client).to have_received(:update_issue)
      .with(repository.github_installation_id, repository.full_name, link.number, { title: "Nuovo titolo" })
  end

  it "sends nothing when the ticket is as last synced: a change that came from GitHub does not bounce back" do
    allow(client).to receive(:update_issue)

    described_class.call(ticket:, client:)

    expect(client).not_to have_received(:update_issue)
  end

  it "closes the issue when the ticket is done" do
    ticket.update!(status: create(:ticket_status, :done, organization:))
    allow(client).to receive(:update_issue).and_return(response("state" => "closed"))

    described_class.call(ticket:, client:)

    expect(client).to have_received(:update_issue)
      .with(anything, anything, link.number, { state: "closed", state_reason: "completed" })
    expect(link.reload.remote_state["closed"]).to be(true)
  end

  it "never sends a description that came in cut, and says so in the history" do
    link.update!(truncated_fields: %w[description])
    ticket.update!(description: "Testo cambiato su CloseYourIt")
    allow(client).to receive(:update_issue)

    described_class.call(ticket:, client:)

    expect(client).not_to have_received(:update_issue)
    expect(ticket.events.where(action: "github_text_kept")).to exist
  end

  it "moves the board card to the column mapped to the new status" do
    doing = create(:ticket_status, organization:, category: :in_progress)
    repository.update!(board_node_id: "PVT_1", board_status_field_id: "F_1",
                       board_columns: { "OPT_TODO" => ticket.status_id, "OPT_DOING" => doing.id })
    link.update!(board_item_node_id: "PVTI_1", board_option_id: "OPT_TODO")
    ticket.update!(status: doing)
    allow(client).to receive(:move_board_item)

    described_class.call(ticket:, client:)

    expect(client).to have_received(:move_board_item)
      .with(repository.github_installation_id, "PVT_1", "PVTI_1", "F_1", "OPT_DOING")
    expect(link.reload.board_option_id).to eq("OPT_DOING")
  end

  def sync_remote(changes) = link.update!(synced_state: link.synced_state.deep_merge("remote" => changes))
  def sync_local(changes) = link.update!(synced_state: link.synced_state.deep_merge("local" => changes))

  it "sends the new description" do
    ticket.update!(description: "Descrizione riscritta qui")
    allow(client).to receive(:update_issue).and_return(response)

    described_class.call(ticket:, client:)

    expect(client).to have_received(:update_issue).with(anything, anything, link.number, { body: a_string_including("Descrizione riscritta qui") })
  end

  it "reopens the issue when the ticket leaves done" do
    sync_remote("closed" => true)
    sync_local("closed" => true)
    allow(client).to receive(:update_issue).and_return(response)

    described_class.call(ticket:, client:)

    expect(client).to have_received(:update_issue).with(anything, anything, link.number, { state: "open", state_reason: "reopened" })
  end

  it "a new type swaps its label and keeps the labels nobody maps" do
    repository.update!(label_kinds: { "bug" => "bug", "task" => "task" })
    sync_remote("labels" => [ "bug", "help wanted" ])
    ticket.update!(kind: :task)
    allow(client).to receive(:update_issue).and_return(response)

    described_class.call(ticket:, client:)

    expect(client).to have_received(:update_issue).with(anything, anything, link.number, { labels: [ "help wanted", "task" ] })
  end

  context "with assignees" do
    def member(github_login)
      create(:account, github_login:).tap { |account| create(:membership, account:, organization:) }
    end

    before { allow(client).to receive(:update_issue).and_return(response) }

    it "sends the GitHub name of the new assignee" do
      ticket.update_column(:assignee_id, member("mario-gh").id)

      described_class.call(ticket:, client:)

      expect(client).to have_received(:update_issue).with(anything, anything, link.number, { assignees: [ "mario-gh" ] })
    end

    it "an unassigned ticket clears the issue's assignees" do
      sync_local("assignee_id" => member("mario-gh").id)

      described_class.call(ticket:, client:)

      expect(client).to have_received(:update_issue).with(anything, anything, link.number, { assignees: [] })
    end

    it "an assignee without a GitHub name leaves the issue's assignees as they are" do
      ticket.update_column(:assignee_id, member(nil).id)

      described_class.call(ticket:, client:)

      expect(client).not_to have_received(:update_issue)
    end
  end

  context "with a board" do
    let(:doing) { create(:ticket_status, organization:, category: :in_progress) }

    before do
      repository.update!(board_node_id: "PVT_1", board_status_field_id: "F_1", board_columns: { "OPT_TODO" => ticket.status_id })
      link.update!(board_item_node_id: "PVTI_1", board_option_id: "OPT_TODO")
      allow(client).to receive(:move_board_item)
    end

    it "a card already in the ticket's column stays put" do
      described_class.call(ticket:, client:)

      expect(client).not_to have_received(:move_board_item)
    end

    it "a status mapped to no column leaves the card where it is" do
      ticket.update!(status: doing)

      described_class.call(ticket:, client:)

      expect(client).not_to have_received(:move_board_item)
      expect(link.reload.board_option_id).to eq("OPT_TODO")
    end
  end

  it "sends nothing while the project keeps the sync off" do
    repository.update!(issue_sync: :off)
    ticket.update!(title: "Nuovo titolo")
    allow(client).to receive(:update_issue)

    described_class.call(ticket:, client:)

    expect(client).not_to have_received(:update_issue)
  end
end
