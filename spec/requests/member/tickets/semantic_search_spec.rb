# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Tickets — ricerca semantica", type: :request do
  let(:org) { create(:organization) }
  let(:member) { create(:account) }
  let(:project) { create(:project, organization: org) }

  before do
    create(:membership, account: member, organization: org, role: :member)
    create(:project_membership, account: member, project: project)
  end

  around do |example|
    old_url = ENV["EMBED_BASE_URL"]
    old_key = ENV["AI_API_KEY"]
    ENV["EMBED_BASE_URL"] = "http://embed.test:7997"
    ENV["AI_API_KEY"] = "test-key"
    example.run
  ensure
    old_url ? ENV["EMBED_BASE_URL"] = old_url : ENV.delete("EMBED_BASE_URL")
    old_key ? ENV["AI_API_KEY"] = old_key : ENV.delete("AI_API_KEY")
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def seeded_ticket(index, title:, project: self.project, organization: org)
    create(:ticket, organization: organization, project: project, title: title).tap do |t|
      t.update_columns(embedding: basis_vector(index), embedding_checksum: "x",
                       embedded_at: Time.current, embedding_version: Ai::Constants::EMBEDDING_VERSION)
    end
  end

  def stub_embed(vector)
    stub_request(:post, "http://embed.test:7997/embeddings")
      .to_return(status: 200, body: { "data" => [ { "index" => 0, "embedding" => vector } ] }.to_json)
  end

  def stub_rerank(results)
    stub_request(:post, "http://embed.test:7997/rerank")
      .to_return(status: 200, body: { "results" => results }.to_json)
  end

  it "rende i risultati in un turbo-frame con il pulsante Cerca (niente più toggle)" do
    sign_in(member)
    get list_member_tickets_path

    expect(response.body).to include('id="tickets-results"')
    expect(response.body).to include('data-test="tickets-search-submit"')
    expect(response.body).not_to include("tickets-semantic-toggle")
  end

  it "semantic=1: risultati per pertinenza (rerank), fuori-soglia esclusi" do
    relevant = seeded_ticket(0, title: "Crash al login su Safari")
    seeded_ticket(7, title: "Colore del footer sbagliato") # ortogonale → escluso
    stub_embed(basis_vector(0))
    stub_rerank([ { "index" => 0, "relevance_score" => 0.95 } ])

    sign_in(member)
    get list_member_tickets_path, params: { q: "utenti non entrano", semantic: "1" }

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(relevant.title)
    expect(response.body).not_to include("Colore del footer sbagliato")
  end

  it "BOLA: un ticket semanticamente identico di un'altra org NON appare mai" do
    other_org = create(:organization)
    foreign_project = create(:project, organization: other_org)
    seeded_ticket(0, title: "Ticket segretissimo altrui", project: foreign_project, organization: other_org)
    stub_embed(basis_vector(0))

    sign_in(member)
    get list_member_tickets_path, params: { q: "segretissimo", semantic: "1" }

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("Ticket segretissimo altrui")
  end

  it "servizio embedding giù → 200 con fallback ILIKE e hint di degrado" do
    create(:ticket, organization: org, project: project, title: "Crash al login")
    stub_request(:post, "http://embed.test:7997/embeddings").to_timeout

    sign_in(member)
    get list_member_tickets_path, params: { q: "Crash", semantic: "1" }

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Crash al login")
    expect(response.body).to include('data-test="tickets-semantic-degraded"')
  end

  it "semantic=1 senza q → nessuna chiamata al servizio, lista normale" do
    embed = stub_request(:post, "http://embed.test:7997/embeddings")
    create(:ticket, organization: org, project: project, title: "Qualsiasi")

    sign_in(member)
    get list_member_tickets_path, params: { semantic: "1" }

    expect(response).to have_http_status(:ok)
    expect(embed).not_to have_been_requested
  end

  it "senza semantic: cerca per significato, come su Idee e Conoscenza (CYRA-553)" do
    relevant = seeded_ticket(0, title: "Crash al login su Safari")
    stub_embed(basis_vector(0))
    stub_rerank([ { "index" => 0, "relevance_score" => 0.95 } ])

    sign_in(member)
    get list_member_tickets_path, params: { q: "utenti non entrano" }

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(relevant.title)
  end

  it "parole esatte (semantic=0): match testuale, nessuna chiamata al servizio" do
    embed = stub_request(:post, "http://embed.test:7997/embeddings")
    create(:ticket, organization: org, project: project, title: "Crash al login")

    sign_in(member)
    get list_member_tickets_path, params: { q: "Crash", semantic: "0" }

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Crash al login")
    expect(embed).not_to have_been_requested
  end

  it "parola che non compare in nessun ticket → «Nessun risultato» col pulsante per azzerare" do
    seeded_ticket(0, title: "Crash al login su Safari")
    stub_embed(basis_vector(0))
    # Il servizio risponde SEMPRE con qualcosa: sono i punteggi bassi a dire che non c'entra nulla.
    stub_rerank([ { "index" => 0, "relevance_score" => 0.0008 } ])

    sign_in(member)
    get list_member_tickets_path, params: { q: "sgrunfiaggine totale", semantic: "1" }

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-test="tickets-no-results"')
    expect(response.body).to include('data-test="tickets-reset-search"')
    expect(response.body).not_to include("Crash al login su Safari")
  end

  it "la barra offre la scelta fra significato e parole esatte (come Idee e Conoscenza)" do
    sign_in(member)
    get list_member_tickets_path

    page = Nokogiri::HTML(response.body)
    expect(page.at_css("input[type='hidden'][name='semantic']")).to be_present
    expect(response.body).to include(I18n.t("shared.tables.search_mode.semantic"))
    expect(response.body).to include(I18n.t("shared.tables.search_mode.exact"))
  end

  it "dichiara sopra i risultati la modalità in uso e la rende reversibile con un clic" do
    seeded_ticket(0, title: "Crash al login su Safari")
    stub_embed(basis_vector(0))
    stub_rerank([ { "index" => 0, "relevance_score" => 0.95 } ])

    sign_in(member)
    get list_member_tickets_path, params: { q: "utenti non entrano", semantic: "1" }

    banner = Nokogiri::HTML(response.body).at_css('[data-test="tickets-search-mode-banner"]')
    expect(banner.text).to include(I18n.t("member.tickets.semantic.using_semantic"))
    switch = Nokogiri::HTML(response.body).at_css('[data-test="tickets-search-mode-switch"]')
    expect(switch["href"]).to include("semantic=0")
    # Il selettore vive FUORI dal frame dei risultati: il link deve uscirne, o resterebbe indietro.
    expect(switch["data-turbo-frame"]).to eq("_top")
  end

  it "trova comunque il ticket appena aperto, il cui indice non è ancora stato calcolato" do
    create(:ticket, organization: org, project: project, title: "Notifiche push mute")
    stub_embed(basis_vector(0))

    sign_in(member)
    get list_member_tickets_path, params: { q: "push", semantic: "1" }

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Notifiche push mute")
  end
end
