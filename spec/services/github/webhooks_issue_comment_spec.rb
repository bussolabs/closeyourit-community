# frozen_string_literal: true

require "rails_helper"

# CYRA-1055 — comment deliveries reach the linked ticket; board card deliveries reach the board.
RSpec.describe "Github::Webhooks issue comments and board cards" do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:installation) { create(:github_installation, organization:) }
  let!(:repository) { create(:github_repository, project:, installation:, issue_sync: :all_issues) }
  let!(:link) { create(:github_issue, repository:, number: 7) }

  describe Github::Webhooks::IssueComment do
    def payload(action: "created", issue: { "number" => 7 }, comment: { "id" => 555, "body" => "Ciao" },
                installation_id: installation.installation_id)
      { "action" => action, "issue" => issue, "comment" => comment, "sender" => { "login" => "bob" },
        "repository" => { "id" => repository.repo_id }, "installation" => { "id" => installation_id } }
    end

    before do
      allow(Github::Issues::Comments).to receive(:import).and_call_original
      allow(Github::Issues::Comments).to receive(:edit).and_return(:edited)
      allow(Github::Issues::Comments).to receive(:delete).and_return(Result.ok(:deleted))
    end

    it "a new comment lands on the ticket, signed by the GitHub account" do
      result = described_class.call(payload: payload)

      expect(result).to be_ok
      expect(link.ticket.comments.find_by!(github_comment_id: 555)).to have_attributes(
        body: "Ciao", author: installation.reload.system_account
      )
      expect(Github::Issues::Comments).to have_received(:import)
        .with(link:, comment: { "id" => 555, "body" => "Ciao" }, account: installation.reload.system_account)
    end

    it "an edit and a deletion follow the comment" do
      expect(described_class.call(payload: payload(action: "edited")).value).to eq(:edited)
      expect(described_class.call(payload: payload(action: "deleted")).value).to eq(:deleted)
    end

    it "another action changes nothing" do
      expect(described_class.call(payload: payload(action: "pinned")).value).to be_nil
    end

    it "without the GitHub account returns an error so the delivery can be retried" do
      allow(Github::Issues::SystemAccount).to receive(:call).and_return(Result.err(AppError.new("no", code: "R422-TEST-001")))

      expect do
        expect(described_class.call(payload: payload).error.code).to eq("R422-TEST-001")
      end.not_to change { link.ticket.comments.count }

      expect(Github::Issues::Comments).not_to have_received(:import)
    end

    it "ignores a repository that is not hooked, a pull request, an issue without a ticket" do
      described_class.call(payload: payload(installation_id: 0))
      described_class.call(payload: payload(issue: { "number" => 7, "pull_request" => {} }))
      described_class.call(payload: payload(issue: { "number" => 8 }))

      expect(Github::Issues::Comments).not_to have_received(:import)
    end
  end

  describe Github::Webhooks::ProjectsV2Item do
    def payload(action: "edited", content_type: "Issue", installation_id: installation.installation_id)
      { "action" => action, "sender" => { "login" => "bob" }, "installation" => { "id" => installation_id },
        "projects_v2_item" => { "content_type" => content_type, "project_node_id" => "PVT_1", "node_id" => "PVTI_1" } }
    end

    before { allow(Github::Issues::Board).to receive(:call).and_return(Result.ok(nil)) }

    it "a moved card reaches the board" do
      described_class.call(payload: payload)

      expect(Github::Issues::Board).to have_received(:call)
        .with(installation:, board_node_id: "PVT_1", item_node_id: "PVTI_1", action: "edited", login: "bob")
    end

    it "ignores a draft card, an unknown action and an unknown installation" do
      described_class.call(payload: payload(content_type: "DraftIssue"))
      described_class.call(payload: payload(action: "reordered"))
      described_class.call(payload: payload(installation_id: 0))

      expect(Github::Issues::Board).not_to have_received(:call)
    end

    it "a suspended organization moves nothing" do
      organization.update_column(:suspended_at, Time.current)

      described_class.call(payload: payload)

      expect(Github::Issues::Board).not_to have_received(:call)
    end
  end
end
