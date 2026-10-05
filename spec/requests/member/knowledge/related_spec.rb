# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member — pannello Knowledge correlata", type: :request do
  let(:org) { create(:organization) }
  # locale esplicito: le asserzioni sul motivo del collegamento leggono il testo che vede l'utente.
  let(:member) { create(:account, locale: "it") }
  let(:project) { create(:project, organization: org) }

  before do
    create(:membership, account: member, organization: org, role: :member)
    create(:project_membership, account: member, project: project)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def embedded_page(index, title:)
    create(:knowledge_page, organization: org, project: project, title: title).tap do |page|
      page.update_columns(embedding: basis_vector(index), embedding_checksum: "x",
                          embedded_at: Time.current, embedding_version: Ai::Constants::EMBEDDING_VERSION)
    end
  end

  def embedded_ticket(title: "Il login non funziona")
    create(:ticket, organization: org, project: project, title: title).tap do |ticket|
      ticket.update_columns(embedding: basis_vector(0), embedding_version: Ai::Constants::EMBEDDING_VERSION)
    end
  end

  describe "POST /member/tickets/:id/knowledge" do
    it "ritorna le pagine correlate del progetto del ticket, col motivo del collegamento" do
      ticket = embedded_ticket
      page = embedded_page(0, title: "Runbook login")
      sign_in(member)

      post knowledge_member_ticket_path(ticket)
      expect(response).to have_http_status(:ok)
      json = response.parsed_body
      expect(json["data"]["pages"].map { |p| p["id"] }).to eq([ page.id ])
      expect(json["data"]["pages"].first).to include("title", "kind_label", "url")
      expect(json["data"]["pages"].first["reason"]).to eq("In comune: login")
    end

    # CYRA-414 — un riquadro che propone materiale fuori tema perde credibilità: senza righe
    # spiegabili il pannello resta vuoto (e il JS toglie del tutto la card).
    it "nessuna pagina davvero pertinente → elenco vuoto" do
      ticket = embedded_ticket(title: "Rifacimento della raccolta dati")
      embedded_page(0, title: "Backup del database su spazio dedicato")
      sign_in(member)

      post knowledge_member_ticket_path(ticket)
      expect(response.parsed_body["data"]["pages"]).to eq([])
    end

    it "quando l'aggancio è dentro il contenuto, il motivo nomina la sezione" do
      ticket = embedded_ticket(title: "Il ripristino è lentissimo")
      page = create(:knowledge_page, organization: org, project: project, title: "Manuale operativo",
                                     body: "Premessa.\n\n## Ripristino dei dati\nI passi da seguire.")
      page.update_columns(embedding: basis_vector(0), embedding_checksum: "x", embedded_at: Time.current,
                          embedding_version: Ai::Constants::EMBEDDING_VERSION)
      sign_in(member)

      post knowledge_member_ticket_path(ticket)
      expect(response.parsed_body["data"]["pages"].first["reason"]).to eq("Ne parla la sezione «Ripristino dei dati»")
    end

    it "mai più di tre voci, anche con molte pagine vicine" do
      ticket = embedded_ticket
      5.times { |i| embedded_page(0, title: "Guida al login numero #{i}") }
      sign_in(member)

      post knowledge_member_ticket_path(ticket)
      expect(response.parsed_body["data"]["pages"].size).to eq(3)
    end

    it "ticket di progetto non visibile → 404 (anti-BOLA)" do
      hidden = create(:ticket, organization: org, project: create(:project, organization: org))
      sign_in(member)

      post knowledge_member_ticket_path(hidden)
      expect(response).to have_http_status(:not_found)
    end

    it "ticket senza embedding e servizio giù → errore envelope (il pannello degrada)" do
      ticket = create(:ticket, organization: org, project: project)
      sign_in(member)

      post knowledge_member_ticket_path(ticket) # nessuna ENV EMBED_* → err di configurazione
      expect(response).not_to have_http_status(:ok)
      expect(response.parsed_body["error"]).to include("code", "message")
    end
  end

  describe "POST /member/monitoring/error/:id/knowledge" do
    it "ritorna le pagine correlate del progetto del gruppo, col motivo del collegamento" do
      group = create(:error_group, project: project, title: "Errore di rete")
      group.update_columns(embedding: basis_vector(0), embedding_version: Ai::Constants::EMBEDDING_VERSION)
      page = embedded_page(0, title: "Runbook errori di rete")
      sign_in(member)

      post knowledge_member_monitoring_error_group_path(group)
      expect(response).to have_http_status(:ok)
      pages = response.parsed_body["data"]["pages"]
      expect(pages.map { |p| p["id"] }).to eq([ page.id ])
      expect(pages.first["reason"]).to eq("In comune: errori, rete")
    end
  end

  it "le show di ticket e gruppo montano il pannello" do
    ticket = create(:ticket, organization: org, project: project)
    group = create(:error_group, project: project)
    sign_in(member)

    get member_ticket_path(ticket)
    expect(response.body).to include("data-test=\"knowledge-related\"")

    get member_monitoring_error_group_path(group)
    expect(response.body).to include("data-test=\"knowledge-related\"")
  end
end
