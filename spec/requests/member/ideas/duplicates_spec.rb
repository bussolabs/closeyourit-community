# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Ideas — idee simili mentre si propone", type: :request do
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

  def seeded_idea(index, title:, project: self.project, organization: org, status: :open)
    create(:idea, organization: organization, project: project, title: title, status: status).tap do |idea|
      idea.update_columns(embedding: basis_vector(index), embedding_checksum: "x",
                          embedded_at: Time.current, embedding_version: Ai::Constants::EMBEDDING_VERSION)
    end
  end

  def stub_embed(vector)
    stub_request(:post, "http://embed.test:7997/embeddings")
      .to_return(status: 200, body: { "data" => [ { "index" => 0, "embedding" => vector } ] }.to_json)
  end

  # CYRA-167 Scenario 1 — chi propone un doppione lo vede prima di crearlo.
  it "ritorna le idee simili visibili (payload con titolo, progetto, stato, voti e url)" do
    twin = seeded_idea(0, title: "Esportare i report in PDF")
    stub_embed(basis_vector(0))

    sign_in(member)
    post duplicates_member_ideas_path, params: { text: "scaricare i dati in pdf" }, as: :json

    expect(response).to have_http_status(:ok)
    ideas = response.parsed_body.dig("data", "ideas")
    expect(ideas.length).to eq(1)
    expect(ideas.first).to include("id" => twin.id, "title" => "Esportare i report in PDF",
                                   "project" => project.name, "votes_count" => 0,
                                   "status_label" => I18n.t("member.ideas.status.open"))
    expect(ideas.first["url"]).to include(twin.id)
  end

  it "segnala anche l'idea già convertita in ticket (il doppione è finito lì)" do
    converted = seeded_idea(0, title: "Già proposta e convertita", status: :converted)
    stub_embed(basis_vector(0))

    sign_in(member)
    post duplicates_member_ideas_path, params: { text: "gia proposta" }, as: :json

    ideas = response.parsed_body.dig("data", "ideas")
    expect(ideas.map { |idea| idea["id"] }).to eq([ converted.id ])
    expect(ideas.first["status_label"]).to eq(I18n.t("member.ideas.status.converted"))
  end

  it "BOLA: la gemella di un progetto non visibile non compare" do
    hidden_project = create(:project, organization: org)
    seeded_idea(0, title: "Gemella nascosta", project: hidden_project)
    stub_embed(basis_vector(0))

    sign_in(member)
    post duplicates_member_ideas_path, params: { text: "gemella" }, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("data", "ideas")).to eq([])
  end

  it "BOLA: la gemella di un'altra org non compare" do
    other_org = create(:organization)
    seeded_idea(0, title: "Gemella altrui",
                project: create(:project, organization: other_org), organization: other_org)
    stub_embed(basis_vector(0))

    sign_in(member)
    post duplicates_member_ideas_path, params: { text: "gemella" }, as: :json

    expect(response.parsed_body.dig("data", "ideas")).to eq([])
  end

  it "testo blank → 422 con envelope errore R422-AI-002" do
    sign_in(member)
    post duplicates_member_ideas_path, params: { text: "" }, as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("R422-AI-002")
  end

  it "servizio giù (5xx) → envelope errore, mai 500 (la proposta resta possibile)" do
    stub_request(:post, "http://embed.test:7997/embeddings").to_return(status: 500, body: "{}")

    sign_in(member)
    post duplicates_member_ideas_path, params: { text: "esportare in pdf" }, as: :json

    expect(response).to have_http_status(:bad_gateway)
    expect(response.parsed_body.dig("error", "code")).to eq("R502-AI-001")
  end

  it "non autenticato → redirect login" do
    post duplicates_member_ideas_path, params: { text: "x" }

    expect(response).to redirect_to(login_path)
  end
end
