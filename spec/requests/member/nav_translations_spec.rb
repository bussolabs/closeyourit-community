# frozen_string_literal: true

require "rails_helper"

# CYRA-438 — la voce che porta alle guide mostrava «translation missing: it.member.nav.guides» dentro
# un menu per il resto italiano, ed era l'unico accesso alle guide da ogni pagina del prodotto. Qui si
# verifica sul menu VERO reso da una pagina: niente segnaposti, la voce si legge «Guide», e sta nel
# primo blocco della navigazione invece che isolata in fondo dopo tutte le sezioni.
RSpec.describe "Member — voci di menu tradotte (CYRA-438)", type: :request do
  let(:org) { create(:organization) }
  # Interfaccia in italiano: è la condizione dello scenario, e il locale di default dell'app è :en.
  let(:owner) { create(:account, locale: "it") }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  def sidebar
    Nokogiri::HTML(response.body).at_css("#member-sidebar") || Nokogiri::HTML(response.body)
  end

  it "il menu non contiene segnaposti di traduzione" do
    get root_path

    expect(response.body).not_to include("translation missing")
    expect(response.body).not_to include("translation_missing")
  end

  it "la voce che porta alle guide si legge «Guide»" do
    get root_path

    voice = sidebar.at_css("[data-test='member-nav-guides']")
    expect(voice).to be_present
    expect(voice.text.strip).to eq("Guide")
    expect(voice["href"]).to eq(member_guides_path)
  end

  # CYRA-903 — Guides left the pinned entries for the footer, right above What's new: always in
  # view below the scrolling menu, so they are not "isolated at the bottom" of a long list (CYRA-438).
  it "keeps the Guides entry in the sidebar footer, outside the scrolling menu" do
    get root_path

    expect(sidebar.at_css("nav [data-test='member-nav-guides']")).to be_nil
    expect(sidebar.at_css("[data-test='member-nav-guides']")).to be_present
  end

  it "il segnaposto non compare nemmeno nel testo letto dai lettori di schermo" do
    get root_path

    labels = Nokogiri::HTML(response.body).css("[aria-label], [title]")
                                          .flat_map { |el| [ el["aria-label"], el["title"] ] }.compact
    expect(labels.grep(/translation missing/i)).to be_empty
  end

  it "la voce resta al suo posto anche in fondo a una verticale" do
    get member_monitoring_servers_path

    expect(sidebar.at_css("[data-test='member-nav-guides']")).to be_present
  end
end
