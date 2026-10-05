# frozen_string_literal: true

require "rails_helper"

# CYRA-433 — suggerimento dei titoli mentre si apre un wikilink `[[…]]` nel corpo. Richiede un
# browser reale (Stimulus deve connettersi e chiamare l'endpoint): il gating js (`js: true` →
# Chrome headless + skip se manca Chrome) è condiviso in `spec/support/js_system.rb`.
RSpec.describe "Member knowledge — suggerimento dei collegamenti", :js, type: :system do
  let(:org) { create(:organization) }
  let!(:project) { create(:project, organization: org) }
  let!(:target) { create(:knowledge_page, organization: org, project: project, title: "Deploy Kamal") }

  let(:owner) do
    account = create(:account)
    create(:membership, account: account, organization: org, role: :owner)
    account
  end

  it "suggerisce i titoli esistenti e completa il collegamento con un clic" do
    sign_in_as(owner)
    visit new_member_knowledge_page_path
    expect(page).to have_css("[data-test='knowledge-form']")

    field = find("[data-test='knowledge-form-body']")
    field.send_keys("Vedi [[dep")

    expect(page).to have_css("[data-test='knowledge-links-suggestion']", text: "Deploy Kamal")
    click_on_test "knowledge-links-suggestion"

    expect(field.value).to eq("Vedi [[Deploy Kamal]]")
    # Scelto il titolo, l'elenco si chiude: il campo torna a essere solo testo.
    expect(page).to have_no_css("[data-test='knowledge-links-suggestion']")
  end

  it "fuori da un collegamento aperto non propone niente" do
    sign_in_as(owner)
    visit new_member_knowledge_page_path
    expect(page).to have_css("[data-test='knowledge-form']")

    find("[data-test='knowledge-form-body']").send_keys("Deploy senza parentesi")

    expect(page).to have_no_css("[data-test='knowledge-links-suggestion']", wait: 2)
  end
end
