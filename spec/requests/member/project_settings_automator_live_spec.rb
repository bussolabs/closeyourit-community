# frozen_string_literal: true

require "rails_helper"

# CYAU-282 — the project chooses whether the automator's live steps may keep the code; off by default.
RSpec.describe "Project automator live code switch", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization:) }

  before do
    create(:membership, account: owner, organization:, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  it "starts off" do
    expect(project.automator_live_code_enabled).to be(false)
  end

  it "shows the switch on the settings page" do
    get member_project_settings_path(project)

    expect(response.body).to include('data-test="project-automator-live-toggle"')
  end

  it "switches the code view on and off" do
    patch member_project_settings_path(project), params: { automator_live_code_enabled: "1" }, as: :json
    expect(response).to have_http_status(:no_content)
    expect(project.reload.automator_live_code_enabled).to be(true)

    patch member_project_settings_path(project), params: { automator_live_code_enabled: "0" }, as: :json
    expect(project.reload.automator_live_code_enabled).to be(false)
  end
end
