# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Projects piattaforme", type: :request do
  let(:org) { create(:organization) }
  let(:admin) { create(:account) }

  before { create(:membership, account: admin, organization: org, role: :owner) }

  def sign_in(acc)
    post login_path, params: { email: acc.email, password: "Secret123!" }
  end

  it "create associa le piattaforme dell'org" do
    sign_in(admin)
    ios = create(:platform, organization: org, code: "ios")
    web = create(:platform, organization: org, code: "web")
    post member_projects_path, params: { name: "Store", key: "STR", color: "indigo", platform_ids: [ "", ios.id, web.id ] }
    expect(Projects::Project.find_by(key: "STR").platforms).to contain_exactly(ios, web)
  end

  it "update sincronizza le piattaforme" do
    sign_in(admin)
    ios = create(:platform, organization: org, code: "ios")
    web = create(:platform, organization: org, code: "web")
    project = create(:project, organization: org)
    project.platforms << ios
    patch member_project_path(project), params: { name: project.name, key: project.key, platform_ids: [ "", web.id ] }
    expect(project.reload.platforms).to contain_exactly(web)
  end

  it "ignora piattaforme di un'altra org (anti-BOLA)" do
    sign_in(admin)
    foreign = create(:platform, organization: create(:organization))
    post member_projects_path, params: { name: "X", key: "X", platform_ids: [ "", foreign.id ] }
    expect(Projects::Project.find_by(key: "X").platforms).to be_empty
  end
end
