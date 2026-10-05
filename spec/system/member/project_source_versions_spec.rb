# frozen_string_literal: true

require "rails_helper"

# Card "Monitoring tools" della show progetto (CYRA-64): i tool sono assunti dalle chiamate ricevute
# (Projects::Source, nessuna dichiarazione manuale) e il pulsante "Cronologia" apre lo storico versioni.
# rack_test (nessun driver JS): si verifica il cablaggio DOM e la navigazione via link.
RSpec.describe "Member project monitoring tools", type: :system do
  before { driven_by(:rack_test) }

  let(:org) { create(:organization, name: "Demo") }
  let(:owner) { create(:account, name: "Olivia Lane") }
  let(:project) { create(:project, organization: org, name: "Storefront") }

  before { create(:membership, account: owner, organization: org, role: :owner) }

  def sign_in_as(account)
    visit login_path
    fill_test "login-email", with: account.email
    fill_test "login-password", with: "Secret123!"
    click_on_test "login-submit"
  end

  it "la card mostra le fonti osservate ed espone il pulsante Cronologia, senza più il form di dichiarazione" do
    create(:project_source, project:, tool_code: "closeyourit-ruby", version: "0.4.0", last_seen_at: 1.hour.ago)

    sign_in_as(owner)
    visit member_project_path(project)

    expect(page).to have_css("[data-test='project-tools']")
    expect(page).to have_css("[data-test='project-tool-closeyourit-ruby']")
    expect(page).to have_css("[data-test='tool-status-ok']")
    # La dichiarazione manuale è stata rimossa: niente più form di dichiarazione tool.
    expect(page).to have_no_css("[data-test='project-tools-form']")
    expect(page).to have_css("[data-test='project-tool-history-closeyourit-ruby']")
  end

  it "dal pulsante Cronologia si apre lo storico versioni con optin/optout e la versione attuale marcata" do
    source = create(:project_source, project:, tool_code: "closeyourit-ruby", version: "0.5.0", last_seen_at: 1.hour.ago)
    create(:project_source_version, source:, version: "0.4.0", first_seen_at: 10.days.ago, last_seen_at: 6.days.ago)
    create(:project_source_version, source:, version: "0.5.0", first_seen_at: 6.days.ago, last_seen_at: 1.hour.ago)

    sign_in_as(owner)
    visit member_project_path(project)
    find("[data-test='project-tool-history-closeyourit-ruby']").click

    expect(page).to have_css("[data-test='member-source-versions']")
    expect(page).to have_css("[data-test='source-versions-list']")
    expect(page).to have_text("0.4.0")
    expect(page).to have_text("0.5.0")
    # La versione attuale della fonte (0.5.0) è marcata.
    expect(page).to have_css("[data-test='source-version-current']")
  end

  it "una fonte senza cronologia mostra lo stato vuoto" do
    source = create(:project_source, project:, tool_code: "closeyourit-ruby", version: nil, last_seen_at: 1.hour.ago)

    sign_in_as(owner)
    visit member_project_source_versions_path(project, source)

    expect(page).to have_css("[data-test='source-versions-empty']")
  end
end
