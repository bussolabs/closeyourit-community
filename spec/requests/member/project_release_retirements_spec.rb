# frozen_string_literal: true

require "rails_helper"

# CYRA-1161 — retire and restore a release from the project's release list. Only who can edit the
# project sees and uses the commands; the retire asks for a message and an explicit confirmation.
RSpec.describe "Member::ProjectReleaseRetirements", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account).tap { |account| create(:membership, account:, organization: org, role: :owner) } }
  let(:project) { create(:project, organization: org) }
  let!(:release) { create(:release, project:, version: "2.4.1") }

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def viewer
    create(:account).tap do |account|
      create(:membership, account:, organization: org, role: :member)
      create(:project_membership, account:, project:)
    end
  end

  def retire(params = { message: "Please update", confirm: 1 })
    post member_project_release_retirement_path(project, release), params:
  end

  it "retires the release with the message and goes back to the project" do
    sign_in(owner)

    retire

    expect(response).to redirect_to(member_project_path(project))
    expect(release.reload).to be_retired
    expect(release.retirement_message).to eq("Please update")
    expect(release.retired_by).to eq(owner)
  end

  it "does not retire without the explicit confirmation" do
    sign_in(owner)

    retire(message: "Please update")

    expect(response).to redirect_to(member_project_path(project))
    expect(flash[:alert]).to be_present
    expect(release.reload).not_to be_retired
  end

  it "does not retire without a message" do
    sign_in(owner)

    retire(message: "", confirm: 1)

    expect(flash[:alert]).to be_present
    expect(release.reload).not_to be_retired
  end

  it "restores a retired release" do
    Projects::Releases::Retire.call(release:, message: "Update", actor: owner)
    sign_in(owner)

    delete member_project_release_retirement_path(project, release)

    expect(response).to redirect_to(member_project_path(project))
    expect(release.reload).not_to be_retired
  end

  it "refuses a member who sees the project without projects.edit" do
    sign_in(viewer)

    retire

    expect(response).to redirect_to(root_path)
    expect(release.reload).not_to be_retired
  end

  it "answers 404 for a release of another project (anti-BOLA)" do
    foreign = create(:release, project: create(:project, organization: create(:organization)))
    sign_in(owner)

    post member_project_release_retirement_path(project, foreign), params: { message: "x", confirm: 1 }

    expect(response).to have_http_status(:not_found)
    expect(foreign.reload).not_to be_retired
  end

  describe "the release list" do
    it "shows the retire command, and the restore command on a retired release, to who edits the project" do
      retired = create(:release, project:, version: "2.4.0")
      Projects::Releases::Retire.call(release: retired, message: "Update", actor: owner)
      sign_in(owner)

      get member_project_path(project)

      html = Capybara.string(response.body)
      expect(html).to have_css("[data-test='project-release-retire-#{release.id}']")
      expect(html).to have_css("[data-test='project-release-restore-#{retired.id}']")
      expect(html).to have_css("[data-test='project-release-retired']", count: 1)
      expect(html).to have_css("dialog[data-test='project-release-retire-modal'] textarea[name='message'][required]", visible: :all)
      expect(html).to have_css("dialog[data-test='project-release-retire-modal'] input[name='confirm'][value='1']", visible: :all)
    end

    it "shows the retired mark but no commands to who cannot edit the project" do
      Projects::Releases::Retire.call(release:, message: "Update", actor: owner)
      sign_in(viewer)

      get member_project_path(project)

      html = Capybara.string(response.body)
      expect(html).to have_css("[data-test='project-release-retired']")
      expect(html).to have_no_css("[data-test^='project-release-retire-']")
      expect(html).to have_no_css("[data-test^='project-release-restore-']")
      expect(html).to have_no_css("dialog[data-test='project-release-retire-modal']", visible: :all)
    end
  end
end
