# frozen_string_literal: true

require "rails_helper"

# CYRA-924 — Restore sits in the row ⋯ menu, one item per older version; its dialog lives outside
# the menu and opens by id (F16, C77). Needs a real browser: Stimulus must connect.
RSpec.describe "Member shared secrets — restore a version from the row menu", :js, type: :system do
  let(:org) { create(:organization, name: "Demo") }
  let!(:env_prod) { create(:environment, organization: org, code: "production", label: "Production") }
  let(:owner) do
    account = create(:account)
    create(:membership, account:, organization: org, role: :owner)
    account
  end

  it "opens the version's dialog from the menu and restores it" do
    Secrets::Shared::Save.call(organization: org, environment: env_prod, name: "API_KEY", value: "one")
    shared = Secrets::Shared::Save.call(organization: org, environment: env_prod, name: "API_KEY", value: "two").value
    old = shared.versions.min_by(&:number)
    sign_in_as(owner)
    visit member_shared_secrets_path

    find("[data-test='shared-secret-menu-api_key']").click
    find("[data-test='shared-secret-rollback-#{old.id}']").click
    dialog = find("dialog#shared-secret-rollback-dialog-#{old.id}")
    expect(dialog).to have_text("API_KEY")
    find("[data-test='shared-secret-rollback-dialog-#{old.id}-confirm']").click

    expect(page).to have_css("[data-test='flash-notice']")
    expect(shared.reload.version_number).to be > old.number + 1
  end
end
