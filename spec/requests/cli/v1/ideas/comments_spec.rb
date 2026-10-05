# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Ideas::Comments", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:idea) { create(:idea, organization:, project:) }

  def token_for(acc)
    Accounts::ApiTokens::Issue.call(account: acc, organization:, name: "CLI").value[:secret]
  end

  it "senza bearer → 401" do
    get "/cli/v1/projects/#{project.id}/ideas/#{idea.id}/comments"
    expect(response).to have_http_status(:unauthorized)
  end

  context "owner" do
    before { create(:membership, account:, organization:, role: :owner) }
    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    it "index → lista cronologica con author" do
      vecchio = create(:idea_comment, idea:, organization:, created_at: 2.hours.ago)
      nuovo = create(:idea_comment, idea:, organization:, created_at: 1.minute.ago)

      get "/cli/v1/projects/#{project.id}/ideas/#{idea.id}/comments", headers: headers

      data = response.parsed_body["data"]
      expect(data.map { |c| c["id"] }).to eq([ vecchio.id, nuovo.id ])
      expect(data.first["author"]).to eq(vecchio.author.name)
      expect(data.first["idea_id"]).to eq(idea.id)
    end

    it "create → 201 e comments_count aggiornato" do
      expect do
        post "/cli/v1/projects/#{project.id}/ideas/#{idea.id}/comments",
             params: { body: "Ottima idea" }, headers: headers
      end.to change { idea.reload.comments_count }.by(1)

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["data"]["body"]).to eq("Ottima idea")
    end

    # CYRA-371 — stesso tetto del canale web: chi discute dalla riga di comando non ha un limite
    # diverso da chi discute dal browser.
    it "create con un intervento argomentato → 201 col testo per intero" do
      testo = "x" * 3_000

      post "/cli/v1/projects/#{project.id}/ideas/#{idea.id}/comments",
           params: { body: testo }, headers: headers

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["data"]["body"]).to eq(testo)
    end

    it "create oltre il tetto → 422 R422-IDEA-005" do
      post "/cli/v1/projects/#{project.id}/ideas/#{idea.id}/comments",
           params: { body: "x" * (Ideas::Constants::COMMENT_MAX_CHARS + 1) }, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-IDEA-005")
    end

    it "create su idea congelata → 422 R422-IDEA-002" do
      frozen = create(:idea, :converted, organization:, project:)

      post "/cli/v1/projects/#{project.id}/ideas/#{frozen.id}/comments",
           params: { body: "tardi" }, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-IDEA-002")
    end

    it "destroy di un commento altrui → 204 (owner ha ideas.comment.delete_any)" do
      comment = create(:idea_comment, idea:, organization:)

      expect do
        delete "/cli/v1/projects/#{project.id}/ideas/#{idea.id}/comments/#{comment.id}", params: { confirm: "1" }, headers: headers
      end.to change(Ideas::Comment, :count).by(-1)
      expect(response).to have_http_status(:no_content)
    end
  end

  context "member con accesso ma senza permessi" do
    before do
      create(:membership, account:, organization:, role: :member)
      create(:project_membership, account:, project:)
    end
    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    it "destroy del commento altrui → 403 (gate ideas.comment.delete_any)" do
      comment = create(:idea_comment, idea:, organization:)

      expect do
        delete "/cli/v1/projects/#{project.id}/ideas/#{idea.id}/comments/#{comment.id}", headers: headers
      end.not_to change(Ideas::Comment, :count)
      expect(response).to have_http_status(:forbidden)
    end

    it "destroy del PROPRIO commento → 204" do
      comment = create(:idea_comment, idea:, organization:, author: account)

      delete "/cli/v1/projects/#{project.id}/ideas/#{idea.id}/comments/#{comment.id}", headers: headers
      expect(response).to have_http_status(:no_content)
    end
  end
end
