# frozen_string_literal: true

require "rails_helper"

# The secrets page parts that need a browser: the row buttons (now from the design system) and the
# folded Use this secret section. Gated by spec/support/js_system.rb (JS_SYSTEM_SPECS=1).
RSpec.describe "Member project secrets in the browser", :js, type: :system do
  let(:org) { create(:organization) }
  let(:owner) do
    create(:account).tap { |a| create(:membership, account: a, organization: org, role: :owner) }
  end
  let(:project) { create(:project, organization: org) }
  let(:environment) { create(:environment, organization: org, code: "production").tap { |e| project.environments << e } }

  before { Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "browser-canary") }

  # CYRA-924 — C64: the eye shows values as text; the pencil opens the row's dialog, filled on open.
  it "reveals and hides a row as text, and edits it in a dialog" do
    sign_in_as(owner)
    visit member_project_secrets_path(project)

    find("[data-test='secret-reveal-api_key']").click
    expect(page).to have_css("#secret-api_key td", text: "browser-canary")
    expect(page).to have_no_field("values[#{environment.id}]", with: "browser-canary")
    find("[data-test='secret-hide-api_key']").click
    expect(page).to have_no_css("#secret-api_key td", text: "browser-canary")

    find("[data-test='secret-edit-api_key']").click
    within("dialog[data-test='secret-dialog-api_key']") do
      expect(page).to have_field("values[#{environment.id}]", with: "browser-canary")
      fill_in "values[#{environment.id}]", with: "browser-canary-2"
      click_on I18n.t("member.secrets.save_row")
    end
    # Overwriting a secret asks for confirmation (CYRA-728).
    click_on I18n.t("member.confirmation_required.confirm")
    expect(page).to have_content(I18n.t("member.secrets.saved"))
    expect(project.secret_variables.find_by(name: "API_KEY").value).to eq("browser-canary-2")
  end

  it "closes the add dialog without saving" do
    sign_in_as(owner)
    visit member_project_secrets_path(project)

    find("[data-test='secret-add']").click
    expect(page).to have_css("dialog[data-test='secret-new-dialog'][open]")
    find("[data-test='secret-cancel-new']").click
    expect(page).to have_no_css("dialog[open]")
  end

  it "submits a protected description edit without capturing the unchanged value" do
    project.update!(secret_approval_enabled: true)
    project.project_environments.find_by!(environment:).update!(approval_required: true)
    sign_in_as(owner)
    visit member_project_secrets_path(project)

    find("[data-test='secret-edit-api_key']").click
    within("dialog[data-test='secret-dialog-api_key']") do
      expect(page).to have_field("values[#{environment.id}]", with: "browser-canary")
      fill_in "description", with: "Updated purpose"
      click_on I18n.t("member.secrets.save_row")
    end
    click_on I18n.t("member.confirmation_required.confirm")
    expect(page).to have_content(I18n.t("member.secrets.saved_with_pending", applied: 0, pending: 1))

    request = Secrets::ChangeRequest.find_by!(project:, name: "API_KEY", status: :pending)
    expect(request).to be_description_only_change
    expect(request.value).to be_nil
    expect(request.proposed_description).to eq("Updated purpose")
    expect(project.secret_variables.find_by!(name: "API_KEY").description).not_to eq("Updated purpose")
  end

  it "opens Use this secret with a click" do
    sign_in_as(owner)
    visit member_project_secrets_path(project)

    expect(page).to have_no_css("[data-test='secret-usage-tab-local']")
    find("details[data-test='secret-usage'] summary").click
    expect(page).to have_css("[data-test='secret-usage-tab-local']")
  end
end
