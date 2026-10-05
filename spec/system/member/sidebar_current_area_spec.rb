# frozen_string_literal: true

require "rails_helper"

# CYRA-583 — closing the group of the current area must not hide where you are: an explicit mark next
# to the group name and an aria-current that assistive tech announces. CYRA-903 — both live on the
# group-name link, the row that stays visible when the group is closed.
RSpec.describe "Member sidebar — l'area in cui mi trovo si riconosce anche a gruppo chiuso", type: :system do
  let(:org) { create(:organization) }

  def account_with(role)
    account = create(:account)
    create(:membership, account: account, organization: org, role: role)
    account
  end

  # `sign_in_as` arriva da JsSystemSupport: attende che il login sia davvero finito prima di
  # navigare. Ridefinirlo qui senza quell'attesa fa rimbalzare al login il caso col browser vero.

  describe "il segno nel markup" do
    before { driven_by(:rack_test) }

    def group_name(group)
      group.first("a[data-nav-label]", visible: :all)
    end

    def gruppi_col_segno
      page.all("#member-sidebar [data-nav-group-id]", visible: :all).select { |gruppo|
        group_name(gruppo).has_css?("[data-test='member-current-area']", visible: :all)
      }.map { |gruppo| gruppo["data-nav-group-id"] }
    end

    def gruppi_correnti
      page.all("#member-sidebar [data-nav-group-id]", visible: :all).select { |gruppo|
        group_name(gruppo)["aria-current"] == "true"
      }.map { |gruppo| gruppo["data-nav-group-id"] }
    end

    # Scenario 1: il segno sta accanto al nome del gruppo, quindi nella riga che si vede pure da
    # chiuso, e lo porta il solo gruppo che contiene la pagina aperta.
    it "il gruppo che contiene la pagina aperta porta un segno accanto al nome, e nessun altro" do
      sign_in_as(account_with(:owner))
      visit member_monitoring_error_groups_path

      expect(gruppi_col_segno).to eq([ "observability" ])
    end

    # Scenario 2: what a screen reader hears — aria-current plus hidden text, since the attribute alone
    # is not announced the same way everywhere.
    it "il nome del gruppo dichiara agli assistivi che è l'area in cui mi trovo" do
      sign_in_as(account_with(:owner))
      visit member_tickets_path

      name = find("[data-test='member-nav-product-overview']", visible: :all)

      expect(name["aria-current"]).to eq("true")
      expect(name.text(:all)).to include(I18n.t("member.nav.current_area"))
    end

    # Un'area corrente alla volta: due gruppi che si dichiarano entrambi correnti direbbero a chi
    # ascolta di stare in due posti insieme.
    it "un solo gruppo si dichiara corrente" do
      sign_in_as(account_with(:owner))
      visit member_tickets_path

      expect(gruppi_correnti).to eq([ "product" ])
    end

    # La Home non sta dentro nessun gruppo: nessun gruppo deve prendersi il merito di contenerla.
    it "su una pagina fuori da ogni gruppo nessun gruppo si dichiara corrente" do
      sign_in_as(account_with(:owner))
      visit root_path

      expect(gruppi_correnti).to be_empty
      expect(gruppi_col_segno).to be_empty
    end
  end

  describe "nel browser, a gruppo chiuso", :js do
    # Mark and declaration stay on the name, not in the leaves the browser hides. No pixel checks: the
    # stylesheet may not be compiled in test.
    it "chiudendo il gruppo dell'area in cui sono, segno e dichiarazione restano sul nome" do
      sign_in_as(account_with(:owner))
      visit member_tickets_path
      expect(page).to have_css("[data-test='member-nav-toggle-product'][aria-expanded='true']")

      find("[data-test='member-nav-toggle-product']").click

      expect(page).to have_css("[data-test='member-nav-toggle-product'][aria-expanded='false']")
      name = find("[data-test='member-nav-product-overview']", visible: :all)
      expect(name["aria-current"]).to eq("true")
      expect(name).to have_css("[data-test='member-current-area']", visible: :all)
    end
  end
end
