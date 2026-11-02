# frozen_string_literal: true

require "rails_helper"

# CYRA-1133 — the council switches on the project and group pages.
RSpec.describe "Project council switch", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization:) }

  before do
    create(:membership, account: owner, organization:, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  it "switches the council on for the project" do
    patch member_project_settings_path(project), params: { council_enabled: "1" }, as: :json
    expect(response).to have_http_status(:no_content)
    expect(project.reload.council_enabled).to be(true)
  end

  it "shows when the group already switched it on" do
    project.update!(group: create(:group, organization:, council_enabled: true))
    get member_project_settings_path(project)
    expect(response.body).to include('data-test="project-council-by-group"')
  end

  it "saves the switch from the group form" do
    group = create(:group, organization:)
    patch member_group_path(group), params: { name: group.name, council_enabled: "1" }
    expect(group.reload.council_enabled).to be(true)
  end
end
