# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::AlertRules", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  it "senza bearer → 401" do
    get "/cli/v1/alert_rules"
    expect(response).to have_http_status(:unauthorized)
  end

  context "owner (org-level alerts.manage)" do
    before { create(:membership, account:, organization:, role: :owner) }

    it "index → 200 con le regole dell'org e meta di paginazione" do
      rule = create(:alerting_rule, organization:)

      get "/cli/v1/alert_rules", headers: headers

      expect(response).to have_http_status(:ok)
      ids = response.parsed_body["data"].map { |x| x["id"] }
      expect(ids).to include(rule.id)
      expect(response.parsed_body["meta"]).to include("page", "per", "total", "total_pages")
    end

    it "index esclude le regole di un'altra org (anti-BOLA)" do
      mine = create(:alerting_rule, organization:)
      other = create(:alerting_rule) # altra org

      get "/cli/v1/alert_rules", headers: headers

      ids = response.parsed_body["data"].map { |x| x["id"] }
      expect(ids).to include(mine.id)
      expect(ids).not_to include(other.id)
    end

    it "show → 200 con id e attributi" do
      rule = create(:alerting_rule, organization:, name: "Nuovi errori")

      get "/cli/v1/alert_rules/#{rule.id}", headers: headers

      data = response.parsed_body["data"]
      expect(data["id"]).to eq(rule.id)
      expect(data["name"]).to eq("Nuovi errori")
    end

    it "show di una regola di un'altra org → 404 (anti-BOLA)" do
      other = create(:alerting_rule)

      get "/cli/v1/alert_rules/#{other.id}", headers: headers

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body["error"]["code"]).to eq("R404-SYSTEM-001")
    end

    it "create → 201, crea la regola con created_by e converte throttle_minutes in secondi" do
      expect do
        post "/cli/v1/alert_rules", headers: headers,
                                    params: { name: "Any new error", event_type: "error_new",
                                              throttle_minutes: 5 }
      end.to change(Alerting::Rule, :count).by(1)

      expect(response).to have_http_status(:created)
      data = response.parsed_body["data"]
      expect(data["throttle_seconds"]).to eq(300)
      expect(Alerting::Rule.find(data["id"]).created_by).to eq(account)
    end

    it "create con name blank → 422 R422-ALERT-001 con details" do
      post "/cli/v1/alert_rules", headers: headers,
                                  params: { name: "", event_type: "error_new", throttle_minutes: 5 }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-ALERT-001")
      expect(response.parsed_body["error"]["details"]).to have_key("name")
    end

    it "create con project_id di un'altra org → la regola si crea ma project_id resta nil (anti-BOLA)" do
      other_project = create(:project) # altra org

      post "/cli/v1/alert_rules", headers: headers,
                                  params: { name: "Scoped", event_type: "error_new", throttle_minutes: 5,
                                            project_id: other_project.id }

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["data"]["project_id"]).to be_nil
    end

    # CYCL-62: la modifica parziale non deve azzerare ciò che non è stato passato. Il caso senza scope
    # (sotto) non lo intercettava: qui la regola parte GIÀ con progetto, ambiente, livello e soglia.
    it "update del solo nome → progetto, ambiente, livello minimo e soglia restano invariati" do
      scoped_project = create(:project, organization:)
      scoped_env = create(:environment, organization:)
      rule = create(:alerting_rule, organization:, name: "Old", event_type: :server_cpu,
                                    project: scoped_project, environment: scoped_env,
                                    min_level: ::Errors::Group.levels["error"], threshold: 90)

      put "/cli/v1/alert_rules/#{rule.id}", headers: headers, params: { name: "New" }

      expect(response).to have_http_status(:ok)
      rule.reload
      expect(rule.name).to eq("New")
      expect(rule.project_id).to eq(scoped_project.id)
      expect(rule.environment_id).to eq(scoped_env.id)
      expect(rule.min_level).to eq(::Errors::Group.levels["error"])
      expect(rule.threshold).to eq(90)
    end

    # Passare esplicitamente il campo vuoto resta il modo per azzerarlo (blank → nil).
    it "update con project_id vuoto → azzera lo scope di progetto (svuotamento esplicito)" do
      rule = create(:alerting_rule, organization:, project: create(:project, organization:))

      put "/cli/v1/alert_rules/#{rule.id}", headers: headers, params: { project_id: "" }

      expect(response).to have_http_status(:ok)
      expect(rule.reload.project_id).to be_nil
    end

    it "update → 200 + campo aggiornato" do
      rule = create(:alerting_rule, organization:, name: "Old")

      put "/cli/v1/alert_rules/#{rule.id}", headers: headers, params: { name: "New" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["name"]).to eq("New")
      expect(rule.reload.name).to eq("New")
    end

    it "update di una regola di un'altra org → 404 (anti-BOLA)" do
      other = create(:alerting_rule)

      put "/cli/v1/alert_rules/#{other.id}", headers: headers, params: { name: "X" }

      expect(response).to have_http_status(:not_found)
    end

    it "update con name blank → 422 R422-ALERT-001 (Save fallita → render_error)" do
      rule = create(:alerting_rule, organization:, name: "Valida")

      put "/cli/v1/alert_rules/#{rule.id}", headers: headers, params: { name: "" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-ALERT-001")
    end

    it "create con project_id, environment_id e min_level valorizzati → li mantiene (rami else di rule_attributes)" do
      scoped_project = create(:project, organization:)
      scoped_env = create(:environment, organization:)

      post "/cli/v1/alert_rules", headers: headers, params: {
        name: "Scoped", event_type: "error_new", throttle_minutes: 5,
        project_id: scoped_project.id, environment_id: scoped_env.id,
        min_level: ::Errors::Group.levels["error"]
      }

      expect(response).to have_http_status(:created)
    end

    # CYRA-236 / Scenario 1: la CLI manda il NOME del livello ("error"). Prima veniva castato a 0 (debug)
    # e la regola scattava su tutto; ora viene salvato l'intero corretto e riletto come tale.
    it "create con min_level per NOME → 201 e salva l'intero corretto" do
      post "/cli/v1/alert_rules", headers: headers, params: {
        name: "Solo gravi", event_type: "error_new", throttle_minutes: 5, min_level: "error"
      }

      expect(response).to have_http_status(:created)
      rule = Alerting::Rule.find(response.parsed_body["data"]["id"])
      expect(rule.min_level).to eq(Errors::Group.levels["error"])
    end

    it "create con min_level per nome inesistente → 422 R422-ALERT-001 invece di salvare un valore qualsiasi" do
      post "/cli/v1/alert_rules", headers: headers, params: {
        name: "Rotta", event_type: "error_new", throttle_minutes: 5, min_level: "bogus"
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-ALERT-001")
    end

    it "destroy → 204 e regola rimossa" do
      rule = create(:alerting_rule, organization:)

      delete "/cli/v1/alert_rules/#{rule.id}", headers: headers

      expect(response).to have_http_status(:no_content)
      expect(Alerting::Rule.exists?(rule.id)).to be(false)
    end
  end

  context "membro senza alerts.manage" do
    before { create(:membership, account:, organization:, role: :member) }

    it "create → 403 R403-CLIAUTH-002" do
      post "/cli/v1/alert_rules", headers: headers,
                                  params: { name: "X", event_type: "error_new", throttle_minutes: 5 }

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
    end

    it "index → 403 (lettura gata da alerts.manage)" do
      get "/cli/v1/alert_rules", headers: headers
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
    end

    it "show → 403 (lettura gata da alerts.manage)" do
      rule = create(:alerting_rule, organization:)
      get "/cli/v1/alert_rules/#{rule.id}", headers: headers
      expect(response).to have_http_status(:forbidden)
    end
  end
end
