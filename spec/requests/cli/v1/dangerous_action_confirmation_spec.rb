# frozen_string_literal: true

require "rails_helper"

# CYRA-728 — «vale anche dalla riga di comando»: il gate della conferma è lo stesso del browser, solo
# la risposta cambia forma (envelope d'errore invece di una pagina).
RSpec.describe "Cli::V1 — conferma delle azioni pericolose", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }
  let!(:project) { create(:project, organization:) }

  before { create(:membership, account:, organization:, role: :owner) }

  it "senza conferma → 422 con il codice della conferma mancante, e il progetto resta" do
    expect { delete "/cli/v1/projects/#{project.id}", headers: headers }
      .not_to change(Projects::Project, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("R422-CONFIRM-001")
    expect(response.parsed_body.dig("error", "details", "permission")).to eq("projects.delete")
  end

  it "il codice NON è quello del permesso negato: il permesso c'è, manca il gesto" do
    delete "/cli/v1/projects/#{project.id}", headers: headers

    expect(response.parsed_body.dig("error", "code")).not_to eq("R403-CLIAUTH-002")
  end

  it "con la conferma l'azione parte" do
    expect { delete "/cli/v1/projects/#{project.id}", params: { confirm: "1" }, headers: headers }
      .to change(Projects::Project, :count).by(-1)
  end

  it "la conferma resta scritta nel registro dei permessi" do
    expect { delete "/cli/v1/projects/#{project.id}", params: { confirm: "1" }, headers: headers }
      .to change { Authorization::Event.where(action: "dangerous_action_confirmed").count }.by(1)
  end

  it "una lettura gated da chiave pericolosa non chiede niente" do
    get "/cli/v1/roles", headers: headers

    expect(response).to have_http_status(:ok)
  end
end
