# frozen_string_literal: true

require "rails_helper"

# CYRA-1055 — the nightly check repairs what GitHub did not deliver, and says so in the history.
RSpec.describe Github::Issues::Reconcile do
  let(:link) { create(:github_issue, github_updated_at: 2.days.ago) }
  let(:repository) { link.repository }
  let(:ticket) { link.ticket }
  let(:client) { instance_double(Github::Client, issue_comments: []) }

  before { repository.update!(issues_reconciled_at: 1.day.ago) }

  def issue(overrides = {})
    { "number" => link.number, "title" => ticket.title, "body" => ticket.description.to_s, "state" => "open",
      "labels" => [], "assignees" => [], "html_url" => link.html_url, "updated_at" => 1.hour.ago.iso8601 }.merge(overrides)
  end

  it "applies a change GitHub never delivered and writes the repair in the ticket's history" do
    allow(client).to receive(:repository_issues).and_return([ issue("title" => "Cambiato su GitHub") ])

    described_class.call(repository:, client:)

    expect(ticket.reload.title).to eq("Cambiato su GitHub")
    expect(ticket.events.find_by(action: "github_reconciled").data["fields"]).to eq(%w[title])
    expect(repository.reload.issues_reconciled_at).to be > 1.minute.ago
  end

  it "sends a ticket change that never reached GitHub" do
    ticket.update!(title: "Cambiato qui")
    allow(client).to receive(:repository_issues).and_return([])
    allow(client).to receive(:update_issue).and_return(issue("title" => "Cambiato qui", "updated_at" => Time.current.iso8601))

    allow(Github::Client).to receive(:new).and_return(client)
    expect do
      described_class.call(repository:, client:)
    end.to have_enqueued_job(Github::Issues::PushJob).with(ticket_id: ticket.id, reconcile: true)
    Github::Issues::PushJob.perform_now(ticket_id: ticket.id, reconcile: true)

    expect(client).to have_received(:update_issue).with(anything, anything, link.number, { title: "Cambiato qui" })
    expect(ticket.events.where(action: "github_reconciled")).to exist
  end

  it "skips a repository whose sync is off" do
    repository.update!(issue_sync: :off)
    allow(client).to receive(:repository_issues)

    described_class.call(repository:, client:)

    expect(client).not_to have_received(:repository_issues)
  end

  it "never checked before, reads only the open issues" do
    repository.update!(issues_reconciled_at: nil)
    allow(client).to receive(:repository_issues).and_return([])

    described_class.call(repository:, client:)

    expect(client).to have_received(:repository_issues)
      .with(repository.github_installation_id, repository.full_name, state: "open", since: nil, page: 1)
  end

  it "reads page after page; a closed issue without a ticket stays on GitHub" do
    closed = Array.new(Github::Client::ISSUES_PAGE_SIZE) { |i| issue("number" => 10_000 + i, "state" => "closed") }
    allow(client).to receive(:repository_issues).and_return(closed, [])
    allow(Github::Issues::Import).to receive(:call)

    described_class.call(repository:, client:)

    expect(client).to have_received(:repository_issues).twice
    expect(Github::Issues::Import).not_to have_received(:call)
  end

  it "brings in an open issue without a ticket" do
    allow(client).to receive(:repository_issues).and_return([ issue("number" => 10_000) ])
    allow(Github::Issues::Import).to receive(:call)

    described_class.call(repository:, client:)

    expect(Github::Issues::Import).to have_received(:call)
      .with(repository:, issue: hash_including("number" => 10_000), with_comments: true)
  end

  it "brings in the comments GitHub never delivered, and says so in the history" do
    allow(client).to receive(:repository_issues).and_return([ issue ])
    allow(client).to receive(:issue_comments)
      .and_return([ { "id" => 777, "body" => "Mai arrivato", "user" => { "login" => "bob" } } ])

    described_class.call(repository:, client:)

    expect(ticket.comments.find_by(github_comment_id: 777).body).to eq("Mai arrivato")
    expect(ticket.events.find_by(action: "github_reconciled").data["fields"]).to eq(%w[comments])
  end

  context "with a board" do
    let(:organization) { ticket.project.organization }
    let(:doing) { create(:ticket_status, organization:, category: :in_progress) }

    before do
      link.update!(board_item_node_id: "PVTI_1", board_option_id: "OPT_TODO")
      repository.update!(board_node_id: "PVT_1", board_status_field_id: "F_1",
                         board_columns: { "OPT_TODO" => ticket.status_id, "OPT_DOING" => doing.id })
      allow(client).to receive(:repository_issues).and_return([])
    end

    def card(number, option, item_id: "PVTI_#{number}")
      { item_id:, board_id: "PVT_1", issue_node_id: "I_#{number}", number:, repo_id: repository.repo_id,
        options: { "F_1" => option } }
    end

    it "moves a card moved while nobody listened, and breaks the link of a card that left the board" do
      repository.update!(issue_sync: :board_issues)
      gone = create(:github_issue, repository:, board_item_node_id: "PVTI_GONE")
      allow(client).to receive(:board_items).and_return([ card(link.number, "OPT_DOING", item_id: "PVTI_1"), card(99_999, "OPT_TODO") ])
      allow(client).to receive(:issue).and_return(nil)

      described_class.call(repository:, client:)

      expect(ticket.reload.status).to eq(doing)
      expect(ticket.events.find_by(action: "github_reconciled").data["fields"]).to eq(%w[status])
      expect(Github::Issue.exists?(gone.id)).to be(false)
    end

    it "with every issue synced, a card off the board keeps its link" do
      allow(client).to receive(:board_items).and_return([])

      described_class.call(repository:, client:)

      expect(link.reload.board_item_node_id).to eq("PVTI_1")
    end
  end

  it "queues pushes instead of racing the issue's webhook work" do
    allow(client).to receive(:repository_issues).and_return([])
    allow(Github::Issues::Push).to receive(:call)

    described_class.call(repository:, client:)

    expect(Github::Issues::Push).not_to have_received(:call)
    expect(Github::Issues::PushJob.new(ticket_id: ticket.id, reconcile: true).concurrency_key)
      .to eq(Github::Issues::EventJob.new(event: "issues", payload: {}, key: link.node_id).concurrency_key)
  end
end
