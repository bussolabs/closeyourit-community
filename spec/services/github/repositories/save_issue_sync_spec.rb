# frozen_string_literal: true

require "rails_helper"

# CYRA-1055 — the project's choices on the GitHub tab: off, every issue, the board's issues only.
RSpec.describe Github::Repositories::Save do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:repository) { create(:github_repository, project:) }
  let(:priority) { create(:ticket_priority, organization:) }
  let(:client) { instance_double(Github::Client) }

  def save(attributes) = described_class.call(repository:, attributes:, client:)

  it "turning the sync on brings the open issues in, a page at a time" do
    expect { save(issue_sync: "all_issues") }
      .to have_enqueued_job(Github::Issues::FirstImportJob).with(repository_id: repository.id)
    expect(repository.reload).to be_issue_sync_all_issues
  end

  it "keeps the labels as label → type and label → priority, whatever their case" do
    save(issue_sync: "all_issues", kind_labels: { "bug" => "Bug", "story" => "" },
         priority_labels: { priority.id => "P1" })

    expect(repository.reload.label_kinds).to eq("bug" => "bug")
    expect(repository.label_priorities).to eq("p1" => priority.id)
  end

  it "reads a newly chosen board once: its title and the field holding the columns" do
    allow(client).to receive(:board).and_return({ title: "Roadmap", field: { "id" => "F_1", "name" => "Status", "options" => [] } })

    save(issue_sync: "board_issues", board_node_id: "PVT_1")

    expect(repository.reload).to have_attributes(board_node_id: "PVT_1", board_title: "Roadmap", board_status_field_id: "F_1")
  end

  it "refuses a board without a column field instead of saving it silently" do
    allow(client).to receive(:board).and_return({ title: "Vuota", field: nil })

    expect(save(issue_sync: "board_issues", board_node_id: "PVT_2").error.code).to eq("R422-GITHUB-013")
  end

  it "refuses a column mapped to a status of another organization" do
    foreign = create(:ticket_status, organization: create(:organization))

    expect(save(board_columns: { "OPT_1" => foreign.id })).to be_err
  end

  it "rejects an unknown sync choice with a field error, not a crash" do
    expect(save(issue_sync: "sometimes")).to be_err
  end
end
