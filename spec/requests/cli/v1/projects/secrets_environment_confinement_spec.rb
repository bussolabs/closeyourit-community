# frozen_string_literal: true

require "rails_helper"

# CYRA-78 — il confine ambienti sui secret via CLI: vale anche per gli UMANI (finora solo i service
# account lo incontravano), lascia un evento "denied" nell'audit col canale da cui arrivava il
# tentativo, e ammette un override per-progetto che vince sulla allow-list dell'organizzazione.
RSpec.describe "Cli::V1 confine ambienti sui secret", type: :request do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:other_project) { create(:project, organization:) }
  let(:staging) { create(:environment, organization:, code: "staging") }
  let(:production) { create(:environment, organization:, code: "production") }
  let(:account) { create(:account) }
  let(:membership) { organization.memberships.find_by!(account:) }
  let(:headers) do
    { "Authorization" => "Bearer #{Accounts::ApiTokens::Issue.call(account:, organization:, name: 'CLI').value[:secret]}" }
  end

  before do
    create(:membership, account:, organization:, role: :member)
    [ project, other_project ].each do |target|
      target.environments << staging
      target.environments << production
      create(:project_membership, account:, project: target)
    end
    # CYRA-721 — il confine ambienti dice DOVE, i permessi dicono COSA: da quando leggere i valori e
    # gestirli sono due chiavi distinte, l'attore di questo blocco le porta entrambe (legge bundle/value
    # e scrive), altrimenti il 403 arriverebbe dal permesso e il confine non verrebbe mai esercitato.
    create(:account_permission, account:, organization:, permission_key: "secrets.manage", effect: :allow)
    create(:account_permission, account:, organization:, permission_key: "secrets.read", effect: :allow)
    membership.update!(secret_environment_codes: [ "staging" ])
  end

  def denied_events(target = project)
    target.secret_events.where(action: "denied", channel: "cli")
  end

  it "un utente umano ristretto a staging è bloccato su production (403 + evento denied)" do
    expect do
      get "/cli/v1/projects/#{project.id}/secrets/bundle", params: { environment: "production" }, headers: headers
    end.to change { denied_events.where(environment: production).count }.by(1)

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body["error"]["code"]).to eq("R403-SECRET-001")
  end

  it "sull'ambiente consentito legge senza lasciare eventi denied" do
    Secrets::Variables::Set.call(project:, environment: staging, name: "A", value: "1")

    expect do
      get "/cli/v1/projects/#{project.id}/secrets/bundle", params: { environment: "staging" }, headers: headers
    end.not_to change { denied_events.count }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["data"]).to eq({ "A" => "1" })
  end

  it "il secret indicato per id su un ambiente vietato → 403 e l'evento porta il nome del secret" do
    variable = Secrets::Variables::Set.call(project:, environment: production, name: "API_KEY", value: "v").value

    delete "/cli/v1/projects/#{project.id}/secrets/#{variable.id}", params: { confirm: "1" }, headers: headers

    expect(response).to have_http_status(:forbidden)
    expect(denied_events.where(environment: production, name: "API_KEY").count).to eq(1)
    expect(project.secret_variables.exists?(variable.id)).to be(true)
  end

  it "l'index non elenca i secret degli ambienti vietati" do
    Secrets::Variables::Set.call(project:, environment: staging, name: "VISIBILE", value: "1")
    Secrets::Variables::Set.call(project:, environment: production, name: "NASCOSTA", value: "1")

    get "/cli/v1/projects/#{project.id}/secrets", headers: headers

    names = response.parsed_body["data"].map { |row| row["name"] }
    expect(names).to contain_exactly("VISIBILE")
  end

  describe "override per-progetto" do
    it "allarga a production solo sul progetto scelto" do
      create(:account_secret_access, account:, project:, organization:, environment_codes: %w[staging production])
      Secrets::Variables::Set.call(project:, environment: production, name: "A", value: "1")

      get "/cli/v1/projects/#{project.id}/secrets/bundle", params: { environment: "production" }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]).to eq({ "A" => "1" })

      get "/cli/v1/projects/#{other_project.id}/secrets/bundle", params: { environment: "production" }, headers: headers
      expect(response).to have_http_status(:forbidden)
    end

    it "restringe anche quando l'organizzazione non pone limiti" do
      membership.update!(secret_environment_codes: [])
      create(:account_secret_access, account:, project:, organization:, environment_codes: %w[staging])

      get "/cli/v1/projects/#{project.id}/secrets/bundle", params: { environment: "production" }, headers: headers
      expect(response).to have_http_status(:forbidden)

      get "/cli/v1/projects/#{other_project.id}/secrets/bundle", params: { environment: "production" }, headers: headers
      expect(response).to have_http_status(:ok)
    end
  end
end
