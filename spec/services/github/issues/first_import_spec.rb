# frozen_string_literal: true

require "rails_helper"

# CYRA-1055 — the first import reads the open issues (or the board's cards) one page per run.
RSpec.describe Github::Issues::FirstImport do
  let(:repository) { create(:github_repository, issue_sync: :all_issues) }
  let(:client) { instance_double(Github::Client) }

  before { allow(Github::Issues::Import).to receive(:call) }

  def import(page: 1) = described_class.call(repository:, page:, client:)

  def item(number) = { item_id: "PVTI_#{number}", board_id: "PVT_1", number:, repo_id: repository.repo_id, options: {} }

  it "reads nothing while the sync is off" do
    repository.update!(issue_sync: :off)
    allow(client).to receive(:repository_issues)

    expect(import.value).to be_nil
    expect(client).not_to have_received(:repository_issues)
  end

  it "a full page asks for the next one" do
    allow(client).to receive(:repository_issues).and_return(Array.new(Github::Client::ISSUES_PAGE_SIZE) { |i| { "number" => i + 1 } })

    expect(import.value).to eq(2)
    expect(Github::Issues::Import).to have_received(:call).exactly(Github::Client::ISSUES_PAGE_SIZE).times
    expect(repository.reload.issues_reconciled_at).to be_nil
  end

  it "the last page starts the nightly check's clock, without notifying anyone" do
    allow(client).to receive(:repository_issues).and_return([ { "number" => 1 } ])

    expect(import.value).to be_nil
    expect(Github::Issues::Import).to have_received(:call)
      .with(repository:, issue: { "number" => 1 }, notify: false, with_comments: true)
    expect(repository.reload.issues_reconciled_at).to be_present
  end

  context "with board issues only" do
    before { repository.update!(issue_sync: :board_issues) }

    it "reads nothing until a board is chosen" do
      allow(client).to receive(:board_items)

      expect(import.value).to be_nil
      expect(client).not_to have_received(:board_items)
    end

    it "imports the open issues on the board, skipping the linked, the gone and the closed ones" do
      repository.update!(board_node_id: "PVT_1", board_status_field_id: "F_1")
      create(:github_issue, repository:, number: 1)
      other = { item_id: "PVTI_9", board_id: "PVT_1", number: 9, repo_id: repository.repo_id + 1, options: {} }
      allow(client).to receive(:board_items).and_return([ item(1), item(2), item(3), item(4), other ])
      allow(client).to receive(:issue).with(anything, repository.full_name, 2).and_return(nil)
      allow(client).to receive(:issue).with(anything, repository.full_name, 3).and_return({ "number" => 3, "state" => "closed" })
      allow(client).to receive(:issue).with(anything, repository.full_name, 4).and_return({ "number" => 4, "state" => "open" })

      expect(import.value).to be_nil
      expect(Github::Issues::Import).to have_received(:call).once
      expect(Github::Issues::Import).to have_received(:call)
        .with(repository:, issue: { "number" => 4, "state" => "open" }, board_item: item(4), notify: false, with_comments: true)
    end
  end
end
