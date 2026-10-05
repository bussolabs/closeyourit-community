# frozen_string_literal: true

require "rails_helper"

# CYRA-871 — quando il controllo dopo il deploy trova la produzione giù o con la versione sbagliata,
# la CI apre un ticket. Uno per versione: rilanciare lo stesso rilascio non lo duplica.
RSpec.describe "Api::V1::DeployFailures", type: :request do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:environment) { create(:environment, organization:, code: "production").tap { |e| project.environments << e } }
  let(:cto) do
    create(:account).tap do |account|
      create(:membership, account:, organization:)
      create(:project_membership, account:, project:)
    end
  end
  let(:scopes) { [ "ingest" ] }
  let(:token) do
    Projects::Tokens::Issue.call(project:, name: "CI", host: "bugs.example.com", environment:,
                                 scopes:).value[:secret]
  end
  let(:headers) { { "Authorization" => "Bearer #{token}" } }
  let(:path) { "/api/v1/projects/#{project.id}/deploy_failures" }
  let(:body) do
    { version: "v1.4.0", reason: "/up produzione non 200 dopo 12 tentativi",
      run_url: "https://github.com/bussolabs/app/actions/runs/1" }
  end

  before do
    organization.update!(cto:)
    create(:ticket_status, organization:, code: "open", position: 0)
    create(:ticket_priority, organization:, code: "high", position: 0)
  end

  it "apre un ticket assegnato al CTO con il motivo e il link alla CI" do
    post path, headers:, params: body

    expect(response).to have_http_status(:created)
    ticket = project.tickets.find(response.parsed_body.dig("data", "id"))
    expect(ticket.title).to eq("Il rilascio v1.4.0 non è in piedi in produzione")
    expect(ticket.description).to include("/up produzione non 200 dopo 12 tentativi")
    expect(ticket.description).to include("https://github.com/bussolabs/app/actions/runs/1")
    expect(ticket.reporter).to eq(cto)
    expect(ticket).to be_kind_bug
    expect(ticket.priority.code).to eq("high")
  end

  it "la stessa versione due volte non duplica il ticket" do
    post path, headers:, params: body
    primo = response.parsed_body.dig("data", "id")

    post path, headers:, params: body

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("data", "id")).to eq(primo)
    expect(project.tickets.count).to eq(1)
  end

  it "senza versione risponde 422" do
    post path, headers:, params: body.except(:version)

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("R422-RELEASE-002")
  end

  it "senza un CTO a cui darlo non apre niente e lo dice" do
    organization.update!(cto: nil)

    post path, headers:, params: body

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.dig("error", "code")).to eq("R409-RELEASE-001")
    expect(project.tickets).to be_empty
  end

  context "con un token di sola lettura" do
    let(:scopes) { [ "read" ] }

    it "rifiuta" do
      post path, headers:, params: body

      expect(response).to have_http_status(:forbidden)
      expect(project.tickets).to be_empty
    end
  end
end
