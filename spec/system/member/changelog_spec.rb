# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member changelog", type: :system do
  before { driven_by(:rack_test) }

  let(:org) { create(:organization, name: "Demo Org") }
  let(:owner) { create(:account, name: "Olivia") }

  before { create(:membership, account: owner, organization: org, role: :owner) }

  def sign_in_as(account)
    visit login_path
    fill_test "login-email", with: account.email
    fill_test "login-password", with: "Secret123!"
    click_on_test "login-submit"
  end

  it "shows the system version in the page footer" do
    sign_in_as(owner)

    expect_test "footer-version"
    within_test("footer-version") do
      expect(page).to have_text(Changelog.current.label)
    end
  end

  it "il modale changelog è presente con almeno una release" do
    sign_in_as(owner)

    expect_test "changelog-modal"
    within_test("changelog-modal") { expect_test "changelog-release" }
  end

  it "dal modale si raggiunge lo storico completo" do
    sign_in_as(owner)

    click_on_test "changelog-view-all"

    expect(page).to have_current_path(member_changelog_path)
    expect_test "changelog-list"
  end

  # CYRA-445 — gli scenari del ticket: sapere cosa è cambiato su una funzione senza scorrere tutta
  # la storia del prodotto, e ritrovare nel menu i nomi che si leggono qui.
  describe "consultare lo storico" do
    let(:releases) do
      [
        Changelog::Release.new(
          version: "0.3.0", date: "2026-07-03",
          sections: [ { label: "Added", items: [
            "**Gruppi di controlli**: i siti si raggruppano. [Disponibilità](/member/monitoring/monitors)"
          ] } ]
        ),
        Changelog::Release.new(
          version: "0.2.0", date: "2026-07-02",
          sections: [ { label: "Fixed", items: [
            "**Etichette storte**: raddrizzate. [Ticket](/member/tickets)"
          ] } ]
        )
      ]
    end

    before { allow(Changelog).to receive(:releases).and_return(releases) }

    # Il widget select è JS-enhanced (chip nascosto senza JS): l'integrazione si prova visitando
    # con il query param, come per gli altri filtri a chip del prodotto.
    it "filtrando per area restano solo le novità di quell'area" do
      sign_in_as(owner)
      visit member_changelog_path(area: [ "uptime" ])

      within_test("changelog-list") do
        expect(page).to have_text("Gruppi di controlli")
        expect(page).not_to have_text("Etichette storte")
      end
    end

    it "cercando dal campo in cima resta solo la novità che contiene quelle parole" do
      sign_in_as(owner)
      visit member_changelog_path

      fill_test "changelog-search", with: "raddrizzate"
      click_on_test "changelog-filter"

      within_test("changelog-list") do
        expect(page).to have_text("Etichette storte")
        expect(page).not_to have_text("Gruppi di controlli")
      end
    end

    it "l'area porta il nome che ha nel menu" do
      sign_in_as(owner)
      visit member_changelog_path

      within_test("changelog-list") do
        expect(page).to have_link(I18n.t("member.nav.uptime"), href: "/member/monitoring/monitors")
        expect(page).not_to have_link("Disponibilità")
      end
    end

    it "quando i filtri non trovano niente lo dice e offre di toglierli" do
      sign_in_as(owner)
      visit member_changelog_path(q: "parolachenonesiste")

      expect_test "changelog-no-results"
      click_on_test "changelog-reset"

      within_test("changelog-list") { expect(page).to have_text("Gruppi di controlli") }
    end
  end
end
