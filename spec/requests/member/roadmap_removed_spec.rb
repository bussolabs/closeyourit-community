# frozen_string_literal: true

require "rails_helper"

# CYRA-883 — the Roadmap pages (project tab and ticket roadmap) were never used and are gone.
# Milestones stay: the agent queues and the ticket form still read them.
RSpec.describe "Roadmap pages removed", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  it "has no roadmap routes left" do
    helpers = Rails.application.routes.url_helpers
    expect(helpers).not_to respond_to(:roadmap_member_project_path)
    expect(helpers).not_to respond_to(:roadmap_member_tickets_path)
    expect(helpers).not_to respond_to(:roadmap_column_member_tickets_path)
  end

  it "shows no Roadmap entry in the sidebar" do
    get member_product_path

    expect(response.body).not_to include('data-test="member-nav-roadmap"')
  end

  it "shows no Roadmap tab on the project page, and keeps Milestones" do
    get member_project_path(project)

    expect(response.body).not_to include('data-test="project-roadmap-link"')
    expect(response.body).to include('data-test="project-milestones-link"')
  end

  it "keeps no keyboard shortcut to the roadmap" do
    get member_product_path

    bindings = JSON.parse(Nokogiri::HTML(response.body).at_css("[data-keyboard-nav-value]")["data-keyboard-nav-value"])
    keys = bindings.map { |binding| binding["key"] }
    expect(keys).to include("t")
    expect(keys).not_to include("r")
  end
end
