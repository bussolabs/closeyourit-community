# frozen_string_literal: true

require "rails_helper"

# CYRA-1278 — the «production waits for a person» switch is saved from the project and the group.
RSpec.describe "Production approval switch", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization:) }

  before do
    create(:membership, account: owner, organization:, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  it "switches it on for the project" do
    patch member_project_settings_path(project), params: { production_approval_required: "1" }, as: :json

    expect(response).to have_http_status(:no_content)
    expect(project.reload.production_approval_required).to be(true)
  end

  it "switches it off again" do
    project.update!(production_approval_required: true)

    patch member_project_settings_path(project), params: { production_approval_required: "0" }, as: :json

    expect(project.reload.production_approval_required).to be(false)
  end

  it "shows the switch in the production section" do
    get member_project_settings_path(project)

    expect(response.body).to include('data-test="project-production-approval-toggle"')
  end

  it "shows when the group already switched it on" do
    project.update!(group: create(:group, organization:, production_approval_required: true))

    get member_project_settings_path(project)

    expect(response.body).to include('data-test="project-production-approval-by-group"')
    expect(response.body).not_to include('data-test="project-production-approval-toggle"')
  end

  it "offers the switch on the group form" do
    get edit_member_group_path(create(:group, organization:))

    expect(response.body).to include('data-test="group-production-approval"')
  end

  it "saves the switch from the group form" do
    group = create(:group, organization:)

    patch member_group_path(group), params: { name: group.name, production_approval_required: "1" }

    expect(group.reload.production_approval_required).to be(true)
    expect(create(:project, organization:, group:).production_approval_required_active?).to be(true)
  end
end
