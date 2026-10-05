# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Tickets — suggerimento duplicati", type: :request do
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

  def seeded_ticket(index, title:, project: self.project, organization: org, status: nil)
    attrs = { organization: organization, project: project, title: title }
    attrs[:status] = status if status
    create(:ticket, **attrs).tap do |t|
      t.update_columns(embedding: basis_vector(index), embedding_checksum: "x",
                       embedded_at: Time.current, embedding_version: Ai::Constants::EMBEDDING_VERSION)
    end
  end

  # Il pannello manda i campi del form, non un testo già impastato dal JS: è così che misura lo
  # stesso testo che misurerà il salvataggio.
  def draft_params(title: "crash quando entro", project_id: nil, **extra)
    { title: title, project_id: project_id || project.id, kind: "bug" }.merge(extra)
  end

  def stub_embed(vector)
    stub_request(:post, "http://embed.test:7997/embeddings")
      .to_return(status: 200, body: { "data" => [ { "index" => 0, "embedding" => vector } ] }.to_json)
  end

  it "ritorna i simili dello stesso progetto, con la somiglianza già scritta" do
    twin = seeded_ticket(0, title: "Crash al login")
    stub_embed(basis_vector(0))

    sign_in(member)
    post duplicates_member_tickets_path, params: draft_params

    expect(response).to have_http_status(:ok)
    tickets = response.parsed_body.dig("data", "tickets")
    expect(tickets.length).to eq(1)
    expect(tickets.first).to include("id" => twin.id, "code" => twin.code, "title" => "Crash al login",
                                     "similarity" => 100)
    expect(tickets.first["similarity_label"]).to include("100")
    expect(tickets.first["url"]).to include(twin.id)
  end

  it "guarda solo il progetto scelto: un gemello di un altro progetto visibile non compare" do
    other_project = create(:project, organization: org)
    create(:project_membership, account: member, project: other_project)
    seeded_ticket(0, title: "Gemello altrove", project: other_project)
    stub_embed(basis_vector(0))

    sign_in(member)
    post duplicates_member_tickets_path, params: draft_params

    expect(response.parsed_body.dig("data", "tickets")).to eq([])
  end

  it "senza progetto scelto risponde una lista vuota: non è un errore, è un form a metà" do
    seeded_ticket(0, title: "Crash al login")
    stub_embed(basis_vector(0))

    sign_in(member)
    post duplicates_member_tickets_path, params: draft_params(project_id: "")

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("data", "tickets")).to eq([])
  end

  it "un lavoro chiuso da più della finestra non è più un candidato" do
    done_status = create(:ticket_status, :done, organization: org)
    old_one = seeded_ticket(0, title: "Crash al login", status: done_status)
    old_one.update_columns(closed_at: (Ticketing::Constants::DUPLICATE_CLOSED_WINDOW + 1.day).ago)
    stub_embed(basis_vector(0))

    sign_in(member)
    post duplicates_member_tickets_path, params: draft_params

    expect(response.parsed_body.dig("data", "tickets")).to eq([])
  end

  it "sotto la soglia del pannello non si propone nulla" do
    seeded_ticket(0, title: "Crash al login")
    stub_embed(blend_vector(0, 1, weight: 0.5)) # 50% di somiglianza

    sign_in(member)
    post duplicates_member_tickets_path, params: draft_params

    expect(response.parsed_body.dig("data", "tickets")).to eq([])
  end

  it "BOLA: il gemello di un'altra org non compare" do
    other_org = create(:organization)
    other_project = create(:project, organization: other_org)
    seeded_ticket(0, title: "Gemello altrui", project: other_project, organization: other_org)
    stub_embed(basis_vector(0))

    sign_in(member)
    post duplicates_member_tickets_path, params: draft_params(project_id: other_project.id)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("data", "tickets")).to eq([])
  end

  it "titolo blank → lista vuota, senza disturbare il servizio" do
    sign_in(member)
    post duplicates_member_tickets_path, params: draft_params(title: "")

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("data", "tickets")).to eq([])
  end

  it "servizio giù (5xx) → envelope errore, mai 500" do
    stub_request(:post, "http://embed.test:7997/embeddings").to_return(status: 500, body: "{}")

    sign_in(member)
    post duplicates_member_tickets_path, params: draft_params

    expect(response).to have_http_status(:bad_gateway)
    expect(response.parsed_body.dig("error", "code")).to eq("R502-AI-001")
  end

  it "non autenticato → redirect login" do
    post duplicates_member_tickets_path, params: draft_params

    expect(response).to redirect_to(login_path)
  end
end
