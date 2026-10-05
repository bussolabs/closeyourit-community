# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::ErrorGroupingRules", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }

  def token_for(acc)
    Accounts::ApiTokens::Issue.call(account: acc, organization:, name: "CLI").value[:secret]
  end

  it "senza bearer → 401" do
    create(:membership, account:, organization:, role: :owner)
    get "/cli/v1/projects/#{project.id}/error_grouping_rules"
    expect(response).to have_http_status(:unauthorized)
  end

  context "owner (può gestire)" do
    before { create(:membership, account:, organization:, role: :owner) }
    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    it "index → 200 in ordine di position" do
      create(:error_grouping_rule, project:, position: 2, fingerprint_key: "b")
      create(:error_grouping_rule, project:, position: 1, fingerprint_key: "a")

      get "/cli/v1/projects/#{project.id}/error_grouping_rules", headers: headers

      expect(response).to have_http_status(:ok)
      keys = response.parsed_body["data"].map { |r| r["fingerprint_key"] }
      expect(keys).to eq(%w[a b])
    end

    it "create → 201 e la regola è persistita" do
      expect do
        post "/cli/v1/projects/#{project.id}/error_grouping_rules",
             params: { field: "exception_type", operator: "contains", value: "Timeout", fingerprint_key: "timeouts" },
             headers: headers
      end.to change(project.error_grouping_rules, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["data"]).to include("field" => "exception_type", "operator" => "contains")
    end

    it "create senza value → 422" do
      post "/cli/v1/projects/#{project.id}/error_grouping_rules",
           params: { field: "exception_type", operator: "contains", fingerprint_key: "x" }, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-ERRGROUPRULE-001")
    end

    # Un enum fuori vocabolario è un 422 onesto, non un 500.
    it "create con field non ammesso → 422 R422-ERRGROUPRULE-002" do
      post "/cli/v1/projects/#{project.id}/error_grouping_rules",
           params: { field: "nonsense", operator: "contains", value: "x", fingerprint_key: "x" }, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-ERRGROUPRULE-002")
    end

    # Il buco chiuso: un enum VUOTO scivolava fino all'assegnazione col 500, non si fermava al 422.
    it "create con field vuoto → 422, non 500" do
      post "/cli/v1/projects/#{project.id}/error_grouping_rules",
           params: { field: "", operator: "contains", value: "x", fingerprint_key: "x" }, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-ERRGROUPRULE-002")
    end

    # active è NOT NULL: la stringa vuota si casta a nil e sfonderebbe il vincolo con un 500 — la
    # validazione di inclusione la ferma come 422 onesto.
    it "create con active vuoto (→ nil) → 422, non 500" do
      post "/cli/v1/projects/#{project.id}/error_grouping_rules",
           params: { field: "exception_type", operator: "contains", value: "x", fingerprint_key: "x", active: "" },
           headers: headers

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "update → 200" do
      rule = create(:error_grouping_rule, project:, value: "old")

      patch "/cli/v1/projects/#{project.id}/error_grouping_rules/#{rule.id}",
            params: { value: "new" }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(rule.reload.value).to eq("new")
    end

    it "destroy → 204" do
      rule = create(:error_grouping_rule, project:)

      delete "/cli/v1/projects/#{project.id}/error_grouping_rules/#{rule.id}", headers: headers

      expect(response).to have_http_status(:no_content)
      expect(Errors::GroupingRule.exists?(rule.id)).to be(false)
    end

    # Anti-BOLA: una regola di un altro progetto non è raggiungibile da questo scope.
    it "update di una regola di un altro progetto → 404" do
      foreign = create(:error_grouping_rule)

      patch "/cli/v1/projects/#{project.id}/error_grouping_rules/#{foreign.id}",
            params: { value: "x" }, headers: headers

      expect(response).to have_http_status(:not_found)
    end
  end

  context "member che vede il progetto ma senza errors.grouping.manage" do
    before do
      create(:membership, account:, organization:, role: :member)
      create(:project_membership, account:, project:)
    end
    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    it "può leggere (la visibilità è il gate)" do
      create(:error_grouping_rule, project:)
      get "/cli/v1/projects/#{project.id}/error_grouping_rules", headers: headers
      expect(response).to have_http_status(:ok)
    end

    it "NON può creare → 403 e nulla viene creato" do
      expect do
        post "/cli/v1/projects/#{project.id}/error_grouping_rules",
             params: { field: "exception_type", operator: "contains", value: "x", fingerprint_key: "x" },
             headers: headers
      end.not_to change(Errors::GroupingRule, :count)

      expect(response).to have_http_status(:forbidden)
    end
  end
end
