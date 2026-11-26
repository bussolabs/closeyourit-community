# frozen_string_literal: true

require "rails_helper"

# CYRA-1055 — "Publish on GitHub": a ticket born here becomes an issue and stays aligned with it.
RSpec.describe Ticketing::Github::PublishIssue do
  let(:repository) { create(:github_repository, issue_sync: :all_issues) }
  let(:ticket) { create(:ticket, project: repository.project, title: "Export lento", description: "Il CSV ci mette due minuti") }
  let(:client) { instance_double(Github::Client) }
  let(:created) do
    { "number" => 42, "id" => 4200, "node_id" => "I_42", "html_url" => "https://github.com/#{repository.full_name}/issues/42",
      "title" => "Export lento", "body" => "Il CSV ci mette due minuti", "state" => "open", "labels" => [],
      "assignees" => [], "user" => { "login" => "closeyourit[bot]" }, "updated_at" => Time.current.iso8601 }
  end

  it "creates the issue with the ticket's text and links them" do
    allow(client).to receive(:create_issue).and_return(created)

    result = described_class.call(ticket:, actor: ticket.reporter, client:)

    expect(result).to be_ok
    expect(client).to have_received(:create_issue)
      .with(repository.github_installation_id, repository.full_name,
            hash_including(title: "Export lento", body: "Il CSV ci mette due minuti"))
    expect(ticket.reload.github_issue.number).to eq(42)
    expect(ticket.events.where(action: "github_issue_published")).to exist
  end

  it "after publishing nothing is pending: the next push sends nothing" do
    allow(client).to receive(:create_issue).and_return(created)
    allow(client).to receive(:update_issue)
    described_class.call(ticket:, actor: ticket.reporter, client:)

    Github::Issues::Push.call(ticket: ticket.reload, client:)

    expect(client).not_to have_received(:update_issue)
  end

  it "does not make a second issue for a ticket already aligned" do
    create(:github_issue, repository:, ticket:)
    allow(client).to receive(:create_issue)

    result = described_class.call(ticket:, actor: ticket.reporter, client:)

    expect(result.error.code).to eq("R409-GITHUB-014")
    expect(client).not_to have_received(:create_issue)
  end

  it "refuses while the project keeps the sync off" do
    repository.update!(issue_sync: :off)

    expect(described_class.call(ticket:, actor: ticket.reporter, client:).error.code).to eq("R422-GITHUB-013")
  end

  it "releases the row lock before HTTP and refuses a second publisher while the request is running" do
    locked = false
    repository.update!(board_node_id: "PVT_1", board_status_field_id: "F_1", board_columns: { "OPT_1" => ticket.status_id })
    allow(ticket).to receive(:with_lock).and_wrap_original do |original, &block|
      original.call do
        locked = true
        begin
          block.call
        ensure
          locked = false
        end
      end
    end
    allow(client).to receive(:create_issue) do
      expect(locked).to be(false)
      other = described_class.call(ticket: Ticketing::Ticket.find(ticket.id), actor: ticket.reporter, client:)
      expect(other.error.code).to eq("R409-GITHUB-016")
      created
    end
    allow(client).to receive(:add_board_item) do
      expect(locked).to be(false)
      "PVTI_42"
    end
    allow(client).to receive(:move_board_item) { expect(locked).to be(false) }

    expect(described_class.call(ticket:, actor: ticket.reporter, client:)).to be_ok
    expect(client).to have_received(:create_issue).once
    expect(client).to have_received(:move_board_item).once
  end

  it "keeps the received issue when saving the link fails and retries only the local write" do
    allow(client).to receive(:create_issue).and_return(created.merge("html_url" => nil))

    expect(described_class.call(ticket:, actor: ticket.reporter, client:).error.code).to eq("R409-GITHUB-016")
    expect(ticket.reload.github_issue_publication.dig("issue", "node_id")).to eq("I_42")
    ticket.update_columns(github_issue_publication: { "issue" => created })

    expect(described_class.call(ticket:, actor: ticket.reporter, client:)).to be_ok
    expect(client).to have_received(:create_issue).once
    expect(ticket.reload.github_issue.number).to eq(42)
  end

  it "does not publish again when the opened webhook linked the issue to another ticket first" do
    allow(client).to receive(:create_issue) do
      create(:github_issue, repository:, node_id: "I_42", number: 42)
      created
    end

    2.times do
      expect(described_class.call(ticket:, actor: ticket.reporter, client:).error.code).to eq("R409-GITHUB-016")
    end

    expect(client).to have_received(:create_issue).once
    expect(repository.issues.count).to eq(1)
    expect(ticket.reload.github_issue_publication.dig("issue", "node_id")).to eq("I_42")
  end

  it "does not retry an uncertain creation" do
    allow(client).to receive(:create_issue).and_raise(Github::Client::Error.new("timeout", code: "R502-GITHUB-001"))
    expect(described_class.call(ticket:, actor: ticket.reporter, client:).error.code).to eq("R422-GITHUB-015")
    expect(described_class.call(ticket:, actor: ticket.reporter, client:).error.code).to eq("R409-GITHUB-016")
    expect(client).to have_received(:create_issue).once
  end

  it "permits retry after a definitive refusal" do
    allow(client).to receive(:create_issue)
      .and_raise(Github::Client::Error.new("not found", code: "R404-GITHUB-010", status: :not_found))
    expect(described_class.call(ticket:, actor: ticket.reporter, client:)).to be_err
    expect(ticket.reload.github_issue_publication).to eq({})

    allow(client).to receive(:create_issue).and_return(created)
    expect(described_class.call(ticket:, actor: ticket.reporter, client:)).to be_ok
  end
end
