# frozen_string_literal: true

require "rails_helper"

# The right column of a project: information closed until asked, the last releases with the rest
# one click away.
RSpec.describe "Project overview panels", :js, type: :system do
  let(:org) { create(:organization) }
  let(:owner) do
    create(:account).tap { |account| create(:membership, account: account, organization: org, role: :owner) }
  end
  let(:group) { create(:group, organization: org, name: "Storefront Suite") }
  let!(:project) { create(:project, organization: org, key: "DASH", name: "Dashboard", group: group) }

  before do
    5.times { |i| create(:release, project: project, version: "1.5.#{i}", environment: "production", created_at: i.minutes.ago) }
    sign_in_as(owner)
    visit member_project_path(project)
  end

  it "opens the information panel on request" do
    expect(page).to have_css("[data-test='project-about'] summary", text: "About this project")
    expect(page).to have_no_css("[data-test='project-group']")

    find("[data-test='project-about'] summary").click

    expect(page).to have_css("[data-test='project-group']", text: "Storefront Suite")
  end

  it "lists three releases and opens them all from See all" do
    expect(page).to have_css("[data-test='project-release-row']", count: 3)
    expect(page).to have_no_css("[data-test='project-release-all-row']")

    find("[data-test='project-releases-all']").click

    expect(page).to have_css("[data-test='project-releases-modal'] [data-test='project-release-all-row']", count: 5)
    expect(page).to have_css("[data-test='project-releases-count']", text: "5 releases")

    find("[data-test='project-releases-close']").click

    expect(page).to have_no_css("[data-test='project-release-all-row']")
  end
end
