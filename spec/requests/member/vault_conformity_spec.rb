# frozen_string_literal: true

require "rails_helper"

# CYRA-931 — the Vault pages follow the shared rules: nothing loose outside a panel (DESIGN.md T1), the
# project's secrets tabs each one panel with tabs, lead, counts and action, explanations float.
RSpec.describe "Vault pages conformity", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:doc) { Nokogiri::HTML(response.body) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  {
    "files" => [ :member_project_secret_assets_path, "project-secret-assets-panel", "project-secret-assets-lead" ],
    "events" => [ :member_project_secret_events_path, "secret-audit-panel", "secret-audit-counts" ],
    "overrides" => [ :member_project_secret_overrides_path, "secret-overrides-panel", "secret-overrides-counts" ]
  }.each do |tab, (path, panel, inside)|
    it "keeps the #{tab} tab in one panel: its tabs, its lead and counts, then the content" do
      get public_send(path, project)

      section = doc.at_css("section[data-test='#{panel}']")
      expect(section.at_css("[data-test='secrets-subnav']")).to be_present
      expect(section.at_css("[data-test='#{inside}']")).to be_present
    end
  end

  {
    "organization secrets" => [ :member_shared_secrets_path, "shared-secrets-delegation-help" ],
    "organization secret files" => [ :member_shared_secret_assets_path, "shared-secret-assets-delegation-help" ],
    "variable search" => [ :member_vault_variables_path, "vault-variables-help" ]
  }.each do |page, (path, test_id)|
    it "floats the explanation of #{page} instead of leaving it in the page" do
      get public_send(path)

      expect(response.body).to match(/<aside[^>]+data-test="#{test_id}"/)
    end
  end

  it "closing the delegation note closes it on both pages that explain it" do
    owner.update!(dismissed_notices: [ "vault_delegation" ])

    get member_shared_secrets_path
    expect(doc.at_css("[data-test='shared-secrets-delegation-help']")).to be_nil
    get member_shared_secret_assets_path
    expect(doc.at_css("[data-test='shared-secret-assets-delegation-help']")).to be_nil
  end

  # Who can read, how the values are protected and how to use them are secondary to the table: they sit
  # side by side in columns under it, not one after the other down the page.
  {
    "organization secrets" => [ -> { member_shared_secrets_path }, "lg:grid-cols-3", 3 ],
    "project secrets" => [ -> { member_project_secrets_path(project) }, "lg:grid-cols-3", 3 ],
    "personal secrets" => [ -> { member_personal_secrets_path }, "lg:grid-cols-2", 2 ]
  }.each do |page, (path, cols, count)|
    it "lays the secondary panels of #{page} side by side" do
      get instance_exec(&path)

      grid = doc.at_css("[data-test='secondary-panels']")
      expect(grid["class"]).to include(cols)
      expect(grid.element_children.size).to eq(count)
    end
  end
end
