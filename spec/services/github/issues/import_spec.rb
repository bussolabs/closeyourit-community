# frozen_string_literal: true

require "rails_helper"

# CYRA-1055 — an issue becomes a linked ticket, once.
RSpec.describe Github::Issues::Import do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let!(:open_status) { create(:ticket_status, organization:, position: 0) }
  let!(:priority) { create(:ticket_priority, organization:, code: "medium") }
  let(:repository) do
    create(:github_repository, project:, issue_sync: :all_issues, installation: create(:github_installation, organization:))
  end

  def issue(overrides = {})
    { "number" => 7, "id" => 77, "node_id" => "I_7", "title" => "Login rotto", "body" => "Non riesco a entrare",
      "state" => "open", "html_url" => "https://github.com/bussolabs/app/issues/7", "user" => { "login" => "alice" },
      "labels" => [], "assignees" => [], "updated_at" => "2026-11-05T10:00:00Z" }.merge(overrides)
  end

  def import(**options) = described_class.call(repository:, issue: issue, **options)

  it "an issue already linked returns its link" do
    link = create(:github_issue, repository:, number: 7)

    expect(import.value).to eq(link)
  end

  it "without the GitHub account nothing is created" do
    failure = Result.err(AppError.new("no", code: "R422-TEST-001"))
    allow(Github::Issues::SystemAccount).to receive(:call).and_return(failure)

    expect(import).to eq(failure)
    expect(repository.issues).to be_empty
  end

  it "a ticket the project refuses leaves no link" do
    failure = Result.err(AppError.new("no", code: "R422-TEST-001"))
    allow(Ticketing::CreateTicket).to receive(:call).and_return(failure)

    expect(import).to eq(failure)
    expect(repository.issues).to be_empty
  end

  it "a closed issue enters in the first done status" do
    done = create(:ticket_status, :done, organization:)

    link = described_class.call(repository:, issue: issue("state" => "closed")).value

    expect(link.ticket.status).to eq(done)
  end

  it "a card enters in the status of its column, with its comments" do
    doing = create(:ticket_status, organization:, category: :in_progress)
    repository.update!(issue_sync: :board_issues, board_node_id: "PVT_1", board_status_field_id: "F_1",
                       board_columns: { "OPT_DOING" => doing.id })
    client = instance_double(Github::Client, issue_comments: [ { "id" => 31, "body" => "Primo", "user" => { "login" => "bob" } } ])
    allow(Github::Client).to receive(:new).and_return(client)
    card = { item_id: "PVTI_7", board_id: "PVT_1", number: 7, repo_id: repository.repo_id, options: { "F_1" => "OPT_DOING" } }

    link = import(board_item: card, with_comments: true).value

    expect(link.ticket.status).to eq(doing)
    expect(link).to have_attributes(board_item_node_id: "PVTI_7", board_option_id: "OPT_DOING")
    expect(link.ticket.comments.find_by(github_comment_id: 31).body).to eq("Primo")
  end

  it "a text longer than the ticket holds enters cut and is marked" do
    link = described_class.call(repository:, issue: issue("body" => "a" * (Ticketing::Constants::DESCRIPTION_MAX_CHARS + 50))).value

    expect(link).to be_truncated("description")
  end

  it "two deliveries racing on the same issue keep one ticket" do
    winner = create(:github_issue, repository:, number: 7)
    allow(repository.issues).to receive(:find_by).and_return(nil, winner)

    result = nil
    expect { result = import.value }.not_to change(Ticketing::Ticket, :count)
    expect(result).to eq(winner)
  end

  it "a link that cannot be written, with no other link to keep, is an error" do
    repository
    expect do
      2.times do
        expect { described_class.call(repository:, issue: issue("html_url" => nil)) }.to raise_error(ActiveRecord::RecordInvalid)
      end
    end.not_to change(Ticketing::Ticket, :count)
    expect(repository.issues).to be_empty
  end
end
