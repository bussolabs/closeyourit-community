# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Knowledge::Publications", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:publication_key) { "kb:global:deploy" }
  let(:path) { "/cli/v1/projects/#{project.id}/knowledge/publications/#{publication_key}" }
  let(:params) { { title: "Deploy", body: "Passi", kind: "guide" } }

  before { create(:membership, account:, organization:, role: :owner) }

  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  it "senza token restituisce 401 envelope" do
    put path, params: params

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body.dig("error", "code")).to eq("R401-CLIAUTH-001")
  end

  it "crea con 201 e restituisce publication_key ed esito nell'envelope" do
    put path, params: params, headers: headers

    expect(response).to have_http_status(:created)
    expect(response.parsed_body["data"]).to include(
      "id" => Knowledge::Page.sole.id,
      "publication_key" => publication_key,
      "project" => project.key
    )
    expect(response.parsed_body["meta"]).to eq("operation" => "created", "adopted_legacy" => false)
  end

  it "rifiuta la convergenza su una pagina che il publisher non può gestire (CYRA-177)" do
    # Pagina esistente con la stessa key, collegata SOLO a un progetto che il member NON vede.
    hidden_project = create(:project, organization:)
    hidden = create(:knowledge_page, organization:, project: hidden_project, publication_key:,
                                      title: "Deploy", body: "Contenuto riservato")

    member = create(:account)
    create(:membership, account: member, organization:, role: :member)
    visible_project = create(:project, organization:)
    create(:project_membership, account: member, project: visible_project)
    create(:account_permission, account: member, organization:, permission_key: "knowledge.edit", effect: :allow)
    member_secret = Accounts::ApiTokens::Issue.call(account: member, organization:, name: "CLI").value[:secret]

    # Publish dalla stessa chiave dal progetto visibile: non deve sovrascrivere la pagina nascosta.
    put "/cli/v1/projects/#{visible_project.id}/knowledge/publications/#{publication_key}",
        params:, headers: { "Authorization" => "Bearer #{member_secret}" }

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.dig("error", "code")).to eq("R403-KNOWLEDGE-003")
    # La pagina resta intatta e non si aggancia al progetto del publisher.
    expect(hidden.reload).to have_attributes(body: "Contenuto riservato")
    expect(hidden.projects).to contain_exactly(hidden_project)
  end

  it "decodifica il path segment una sola volta senza mutare la chiave" do
    encoded_path = "/cli/v1/projects/#{project.id}/knowledge/publications/source%3Arelease~v1"

    put encoded_path, params: params, headers: headers

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig("data", "publication_key")).to eq("source:release~v1")
    expect(Knowledge::Page.sole.publication_key).to eq("source:release~v1")
  end

  { "confine di un carattere" => "a", "confine di 255 caratteri" => "a" * 255 }.each do |label, key|
    it "accetta #{label} senza mutare la chiave" do
      boundary_path = "/cli/v1/projects/#{project.id}/knowledge/publications/#{key}"

      put boundary_path, params: params, headers: headers

      expect(response).to have_http_status(:created)
      expect(response.parsed_body.dig("data", "publication_key")).to eq(key)
      expect(Knowledge::Page.sole.publication_key).to eq(key)
    end
  end

  it "retry idempotente aggiorna la stessa pagina con 200" do
    put path, params: params, headers: headers
    page_id = response.parsed_body.dig("data", "id")

    expect { put path, params: params.merge(body: "Nuovi passi"), headers: headers }
      .not_to change(Knowledge::Page, :count)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("data", "id")).to eq(page_id)
    expect(response.parsed_body.dig("data", "body")).to eq("Nuovi passi")
    expect(response.parsed_body.dig("meta", "operation")).to eq("updated")
  end

  it "adotta una sola legacy e restituisce conflitto su N match" do
    legacy = create(:knowledge_page, project:, title: "Deploy", body: "Vecchia")

    put path, params: params, headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("data", "id")).to eq(legacy.id)
    expect(response.parsed_body.dig("meta", "adopted_legacy")).to be(true)

    other_path = "/cli/v1/projects/#{project.id}/knowledge/publications/kb:ambiguous"
    create_list(:knowledge_page, 2, project:, title: "Ambigua")
    put other_path, params: params.merge(title: "Ambigua"), headers: headers

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.dig("error", "code")).to eq("R409-KNOWLEDGE-001")
  end

  it "membro visibile senza knowledge.edit riceve 403; con permesso può pubblicare" do
    member = create(:account)
    create(:membership, account: member, organization:, role: :member)
    create(:project_membership, account: member, project:)
    member_secret = Accounts::ApiTokens::Issue.call(account: member, organization:, name: "CLI").value[:secret]
    member_headers = { "Authorization" => "Bearer #{member_secret}" }

    put path, params:, headers: member_headers
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.dig("error", "code")).to eq("R403-CLIAUTH-002")

    Authorization::SetAccountPermissions.call(
      organization:, account: member, allow_keys: [ "knowledge.edit" ], actor: account
    )
    put path, params:, headers: member_headers
    expect(response).to have_http_status(:created)
  end

  it "progetto non visibile nella stessa organization resta 404 senza leak" do
    member = create(:account)
    create(:membership, account: member, organization:, role: :member)
    member_secret = Accounts::ApiTokens::Issue.call(account: member, organization:, name: "CLI").value[:secret]
    hidden = create(:project, organization:)

    put "/cli/v1/projects/#{hidden.id}/knowledge/publications/#{publication_key}",
        params: params, headers: { "Authorization" => "Bearer #{member_secret}" }

    expect(response).to have_http_status(:not_found)
    expect(Knowledge::Page.count).to eq(0)
  end

  it "progetto di un'altra organization resta 404 senza leak" do
    foreign = create(:project)

    put "/cli/v1/projects/#{foreign.id}/knowledge/publications/#{publication_key}",
        params: params, headers: headers

    expect(response).to have_http_status(:not_found)
    expect(Knowledge::Page.count).to eq(0)
  end

  it "payload invalido restituisce 422 con details e non adotta la legacy" do
    legacy = create(:knowledge_page, project:, title: "Deploy", body: "Vecchia")

    put path, params: params.merge(body: ""), headers: headers

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("R422-KNOWLEDGE-005")
    expect(response.parsed_body.dig("error", "details", "body")).to be_present
    expect(legacy.reload.publication_key).to be_nil
  end

  it "kind sconosciuto restituisce 422 envelope" do
    put path, params: params.merge(kind: "unknown"), headers: headers

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("R422-KNOWLEDGE-005")
    expect(response.parsed_body.dig("error", "details", "kind")).to be_present
  end

  {
    "slash percent-encoded" => "source%2Fdeploy",
    "query separator percent-encoded" => "source%3Fdraft=1",
    "control character percent-encoded" => "source%0Adeploy",
    "chiave oltre 255 caratteri" => "a" * 256,
    "chiave blank rappresentabile" => "%20%20%20",
    "spazi che muterebbero l'identità" => "%20source%20"
  }.each do |label, segment|
    it "restituisce 422 per #{label} senza creare o adottare" do
      legacy = create(:knowledge_page, project:, title: "Deploy", body: "Vecchia")
      invalid_path = "/cli/v1/projects/#{project.id}/knowledge/publications/#{segment}"

      put invalid_path, params: params, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("R422-KNOWLEDGE-005")
      expect(response.parsed_body.dig("error", "details", "publication_key")).to be_present
      expect(legacy.reload).to have_attributes(publication_key: nil, body: "Vecchia")
      expect(project.knowledge_pages.count).to eq(1)
    end
  end
end
