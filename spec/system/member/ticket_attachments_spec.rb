# frozen_string_literal: true

require "rails_helper"

# Dropzone allegati nel dettaglio ticket.
# NOTA: i system spec girano con rack_test (nessun driver JS) → il comportamento
# Stimulus (auto-submit on change, stato "Caricamento…", drag&drop) NON è eseguibile
# qui e va verificato manualmente. Questi test coprono il cablaggio DOM e il
# fallback no-JS (selezione file + click sul bottone "Aggiungi" → upload reale).
RSpec.describe "Member ticket attachments", type: :system do
  before { driven_by(:rack_test) }

  let(:org) { create(:organization, name: "Demo") }
  let(:owner) { create(:account, name: "Olivia Lane") }
  let(:project) { create(:project, organization: org, name: "Storefront", key: "STR") }
  let(:ticket) { create(:ticket, organization: org, project: project) }

  before { create(:membership, account: owner, organization: org, role: :owner) }

  def sign_in_as(account)
    visit login_path
    fill_test "login-email", with: account.email
    fill_test "login-password", with: "Secret123!"
    click_on_test "login-submit"
  end

  it "espone il wiring Stimulus della dropzone (controller, input, status)" do
    ticket
    sign_in_as(owner)
    visit member_ticket_path(ticket)
    click_on_test "member-ticket-attachments-open" # CYRA-883: with no files the drop area opens on click

    expect(page).to have_css("form[data-controller='attachment-upload']")
    expect(page).to have_css(
      "input#member-ticket-attachment-input" \
      "[data-attachment-upload-target='input']"
    )
    expect(page).to have_css("[data-attachment-upload-target='status']", visible: :all)
  end

  it "fallback no-JS: seleziona file + click Aggiungi → allega al ticket" do
    ticket
    sign_in_as(owner)
    visit member_ticket_path(ticket)
    click_on_test "member-ticket-attachments-open" # CYRA-883: with no files the drop area opens on click

    attach_file "member-ticket-attachment-input",
                Rails.root.join("spec/fixtures/files/screenshot.png").to_s
    click_on_test "member-ticket-attachment-submit"

    expect(ticket.reload.files).to be_attached
  end

  it "un video allegato si vede con il lettore integrato, non solo come link di download" do
    ticket.files.attach(io: StringIO.new("\x00\x00\x00\x14ftypqt  "), filename: "clip.mov",
                        content_type: "video/quicktime")
    sign_in_as(owner)
    visit member_ticket_path(ticket)

    file = ticket.files.first
    expect(page).to have_css("[data-test='member-ticket-attachment-#{file.id}'] video[controls]")
  end
end
