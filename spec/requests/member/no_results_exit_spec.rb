# frozen_string_literal: true

require "rails_helper"

# CYRA-687 — da un elenco filtrato che non trovava niente non si usciva: venti elenchi senza
# azzeramento, e due pagine nascondevano perfino la barra dei filtri insieme alle righe.
RSpec.describe "Member — uscita dagli elenchi filtrati senza risultati (CYRA-687)", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let!(:project) { create(:project, organization: org) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  it "sui gruppi la barra dei filtri resta visibile e compare l'azzeramento" do
    create(:group, organization: org, name: "Piattaforma")

    get member_groups_path(q: "zzz-niente")

    html = Capybara.string(response.body)
    aggregate_failures do
      expect(html).to have_css("[data-test='groups-toolbar']")
      expect(html).to have_css("[data-test='groups-no-results']")
      # CYRA-694 — il marker ft=1 fa dimenticare anche i filtri ricordati in sessione.
      expect(html.find("[data-test='groups-reset-search']")[:href]).to eq(member_groups_path(ft: "1"))
    end
  end

  it "sui gruppi senza filtri lo stato vuoto vero resta quello che insegna" do
    get member_groups_path

    expect(Capybara.string(response.body)).to have_css("[data-test='groups-empty']")
  end

  it "sulle piattaforme il nessun-risultato offre l'azzeramento" do
    create(:platform, organization: org, label: "Web")

    get member_platforms_path(q: "zzz-niente")

    html = Capybara.string(response.body)
    # CYRA-694 — il marker ft=1 fa dimenticare anche i filtri ricordati in sessione.
    expect(html.find("[data-test='platforms-reset-filters']")[:href]).to eq(member_platforms_path(ft: "1"))
  end

  it "sul carico di lavoro filtrato il vuoto è un nessun-risultato con uscita, non la lezione introduttiva" do
    get list_member_workload_actions_path(q: "zzz-niente")

    html = Capybara.string(response.body)
    aggregate_failures do
      expect(html).to have_css("[data-test='workload-actions-no-results']")
      expect(html).not_to have_css("[data-test='workload-actions-empty']")
    end
  end
end
