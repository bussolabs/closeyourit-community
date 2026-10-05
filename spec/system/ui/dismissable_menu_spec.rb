# frozen_string_literal: true

require "rails_helper"

# Verifica comportamentale dello Stimulus condiviso `ui--dismissable` (Esc + click-esterno sui
# menu <details> di disclosure — user-menu, org switcher; il kebab di riga ha già lo stesso
# comportamento via `ui--row-menu`, WP2.8). Richiede un browser reale (Stimulus deve connettersi):
# il gating js (`js: true` → driver Chrome headless + skip se manca Chrome) è condiviso in
# `spec/support/js_system.rb`; opt-in esplicito `JS_SYSTEM_SPECS=1`.
RSpec.describe "Ui — menu <details> chiudibili (Esc + click esterno)", :js, type: :system do
  let(:org) { create(:organization, name: "Demo") }
  let(:account) do
    acc = create(:account)
    create(:membership, account: acc, organization: org, role: :owner)
    acc
  end

  it "Escape chiude lo user-menu aperto e riporta il focus al summary" do
    sign_in_as(account)
    visit root_path

    summary = find("[data-test='member-user-menu']")
    summary.click
    expect_test("logout")

    summary.send_keys(:escape)

    expect(page).to have_no_css("[data-test='logout']")
    expect(page.evaluate_script("document.activeElement === arguments[0]", summary.native)).to be(true)
  end

  it "click fuori chiude lo user-menu aperto" do
    sign_in_as(account)
    visit root_path

    summary = find("[data-test='member-user-menu']")
    summary.click
    expect_test("logout")

    # Click sintetico sul <body> (via JS, non un click Selenium con coordinate reali): il target
    # dell'evento bubbla a document dove il controller ascolta, senza dipendere dalla dimensione
    # visiva/posizione di un elemento "innocuo" specifico nella topbar.
    page.execute_script("document.body.click()")

    expect(page).to have_no_css("[data-test='logout']")
  end

  # With a single organization there is no menu to open (CYRA-898): a second one brings it back.
  it "closes the open organization switcher on an outside click" do
    create(:membership, account: account, organization: create(:organization, name: "Second"), role: :member)
    sign_in_as(account)
    visit root_path

    summary = find("[data-test='member-org-switcher']")
    summary.click
    expect_test("member-org-switch-#{org.id}")

    page.execute_script("document.body.click()")

    expect(page).to have_no_css("[data-test='member-org-switch-#{org.id}']")
  end
end
