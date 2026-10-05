# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Ideas::Cases", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:idea) { create(:idea, organization:, project:) }

  def token_for(acc)
    Accounts::ApiTokens::Issue.call(account: acc, organization:, name: "CLI").value[:secret]
  end

  def cases_path(target = idea)
    "/cli/v1/projects/#{project.id}/ideas/#{target.id}/cases"
  end

  it "senza bearer → 401" do
    post cases_path, params: { title: "Case" }
    expect(response).to have_http_status(:unauthorized)
  end

  context "owner" do
    before { create(:membership, account:, organization:, role: :owner) }
    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    it "create → 201, cases_count +1 e serializer con idea_id" do
      expect do
        post cases_path, params: { title: "Check-in QR", description: "Lo staff scannerizza il QR all'ingresso" },
                         headers: headers
      end.to change { idea.reload.cases_count }.by(1)

      expect(response).to have_http_status(:created)
      data = response.parsed_body["data"]
      expect(data).to include("title" => "Check-in QR", "idea_id" => idea.id)
      expect(data["description"]).to eq("Lo staff scannerizza il QR all'ingresso")
    end

    it "create con titolo vuoto → 422 R422-IDEA-005 con details" do
      post cases_path, params: { title: "", description: "x" }, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      error = response.parsed_body["error"]
      expect(error["code"]).to eq("R422-IDEA-005")
      expect(error["details"]).to have_key("title")
    end

    it "create su idea congelata → 422 R422-IDEA-002, nessun case" do
      frozen = create(:idea, :converted, organization:, project:)

      expect do
        post cases_path(frozen), params: { title: "tardi" }, headers: headers
      end.not_to change(Ideas::Case, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-IDEA-002")
    end

    it "create su idea di un ALTRO progetto → 404 (anti-BOLA)" do
      foreign = create(:idea, organization:)

      post "/cli/v1/projects/#{project.id}/ideas/#{foreign.id}/cases",
           params: { title: "Case" }, headers: headers

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body["error"]["code"]).to match(/^R404-/)
    end

    it "update → 200 e modifica il case" do
      kase = create(:idea_case, idea:)

      put "#{cases_path}/#{kase.id}", params: { title: "Aggiornato", description: "nuova descrizione" },
                                      headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]).to include("title" => "Aggiornato")
      expect(kase.reload.title).to eq("Aggiornato")
    end

    it "update con titolo vuoto → 422 R422-IDEA-005 con details" do
      kase = create(:idea_case, idea:)

      put "#{cases_path}/#{kase.id}", params: { title: "" }, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-IDEA-005")
    end

    it "destroy → 204 e rimuove il case" do
      kase = create(:idea_case, idea:)

      expect do
        delete "#{cases_path}/#{kase.id}", headers: headers
      end.to change { idea.reload.cases_count }.by(-1)

      expect(response).to have_http_status(:no_content)
      expect(Ideas::Case.exists?(kase.id)).to be(false)
    end

    it "update di un case su idea congelata → 422 R422-IDEA-002" do
      kase = create(:idea_case, idea:)
      idea.update!(status: :archived)

      put "#{cases_path}/#{kase.id}", params: { title: "tardi" }, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-IDEA-002")
    end

    it "update di un case di un'ALTRA idea → 404 (anti-BOLA)" do
      other_idea = create(:idea, organization:, project:)
      foreign_case = create(:idea_case, idea: other_idea)

      put "#{cases_path}/#{foreign_case.id}", params: { title: "x" }, headers: headers

      expect(response).to have_http_status(:not_found)
    end
  end

  context "member con accesso ma senza ideas.edit" do
    before do
      create(:membership, account:, organization:, role: :member)
      create(:project_membership, account:, project:)
    end
    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    it "create su idea altrui → 403, nessun case" do
      expect do
        post cases_path, params: { title: "Case" }, headers: headers
      end.not_to change(Ideas::Case, :count)

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to match(/^R403-/)
    end

    it "l'AUTORE aggiunge un case alla propria idea anche senza ideas.edit → 201" do
      own = create(:idea, organization:, project:, author: account)

      expect do
        post cases_path(own), params: { title: "Mio case" }, headers: headers
      end.to change { own.reload.cases_count }.by(1)

      expect(response).to have_http_status(:created)
    end
  end
end
