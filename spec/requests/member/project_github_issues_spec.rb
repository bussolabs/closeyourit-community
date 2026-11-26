# frozen_string_literal: true

require "rails_helper"

# CYRA-1055 — the issue sync is set from the project's GitHub tab, next to today's switches.
RSpec.describe "Member::ProjectGithub — issue sync", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let!(:owner_m) { create(:membership, account: owner, organization: org, role: :owner) }
  let(:project) { create(:project, organization: org) }
  let!(:repository) do
    create(:github_repository, project:, installation: create(:github_installation, organization: org))
  end

  before { post login_path, params: { email: owner.email, password: "Secret123!" } }

  it "with the sync off the panel offers the three choices and no board" do
    get member_project_github_path(project)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("github-issues-panel", "github-issue-sync")
    expect(response.body).not_to include("github-board")
  end

  it "saves the choice from the panel's own form" do
    patch member_project_github_path(project), params: { issue_sync_form: "1", issue_sync: "all_issues" }

    expect(response).to redirect_to(member_project_github_path(project))
    expect(repository.reload).to be_issue_sync_all_issues
  end

  it "with the sync on names the App permission still missing" do
    repository.update!(issue_sync: :all_issues)
    client = instance_double(Github::Client, installation: { "permissions" => { "issues" => "read" } },
                                             organization_boards: [ { "id" => "PVT_1", "title" => "Roadmap" } ])
    allow(Github::Client).to receive(:new).and_return(client)

    get member_project_github_path(project)

    expect(response.body).to include("github-issues-permissions", "github-board", "Roadmap")
  end
end
