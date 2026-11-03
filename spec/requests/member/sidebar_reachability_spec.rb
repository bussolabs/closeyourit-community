# frozen_string_literal: true

require "rails_helper"

# CYRA-365 — una funzione intera del prodotto (le attività personali) stava fuori dal menu: ci si
# arrivava solo da un'icona senza nome nella barra in alto, e la lista era ferma a zero. La regola
# che questa spec tiene ferma è più generale del caso singolo: se una pagina ha funzioni proprie, il
# menu la nomina — non la si scopre passandoci sopra col mouse, né aprendo un blocco chiuso.
RSpec.describe "Member sidebar — raggiungibilità", type: :request do
  let(:org) { create(:organization) }
  let(:doc) { Nokogiri::HTML(response.body) }

  let(:owner) do
    create(:account).tap { |account| create(:membership, account:, organization: org, role: :owner) }
  end

  before do
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  # The pinned slot that held the todo lists now opens the agents at work; the lists keep their top-bar icon.
  it "pins the live automator entry, with its name" do
    get root_path

    entries = doc.css("#member-sidebar [data-test='member-nav-automator-live']")

    expect(entries.size).to eq(1)
    expect(entries.first.text.strip).to eq(I18n.t("member.nav.automator_live"))
    expect(entries.first["href"]).to eq(member_agents_live_sessions_path)
  end

  it "lights the live entry when you are on it, for screen readers too" do
    get member_agents_live_sessions_path

    expect(doc.at_css("[data-test='member-nav-automator-live'][aria-current='page']")).to be_present
  end

  it "keeps the todo lists one click away from the top-bar icon" do
    get root_path

    expect(response.body).to include('data-test="member-nav-todos"')
    expect(doc.at_css("#member-sidebar [data-test='member-nav-home-todos']")).to be_nil
  end

  # Il guasto originale: una funzione dietro un blocco da aprire. La regola nasceva assoluta — nessuna
  # voce dentro un <details> — e CYRA-521 l'ha ristretta consapevolmente: con la sidebar unica i gruppi
  # collassabili sono l'impianto, e le voci di dominio ci vivono dentro. Resta protetto ciò che il
  # guasto riguardava davvero: le cinque cose che si aprono ogni giorno, che stanno sempre in cima e a
  # vista. Il prezzo accettato è che una funzione dentro un gruppo mai aperto resta meno scopribile —
  # il contrappeso sono le scorciatoie da tastiera (sotto) e il catalogo delle guide.
  it "nessuna delle voci quotidiane vive dentro un blocco da aprire" do
    get root_path

    fisse = %w[member-nav-home member-nav-approvals member-nav-conversations
               member-nav-automator-live member-nav-guides]
    dentro_blocchi = fisse.select { |voce| doc.at_css("#member-sidebar details a[data-test='#{voce}']") }

    expect(dentro_blocchi).to be_empty
  end

  # Il contrappeso alla restrizione qui sopra: se una voce di dominio può stare dentro un gruppo
  # chiuso, il gruppo che la contiene deve almeno avere un nome leggibile — non un'icona muta.
  it "ogni gruppo si presenta con un nome, non con la sola icona" do
    get root_path

    doc.css("#member-sidebar details > summary").each do |summary|
      expect(summary.text.strip).not_to be_empty, "un gruppo della sidebar non ha nome"
    end
  end

  it "da tastiera si raggiungono come le altre destinazioni del menu" do
    get root_path

    scorciatoie = JSON.parse(doc.at_css("[data-keyboard-nav-value]")["data-keyboard-nav-value"])

    expect(scorciatoie.map { |voce| voce["url"] }).to include(member_todo_lists_path)
  end
end
