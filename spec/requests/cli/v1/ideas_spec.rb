# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Ideas", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }

  def token_for(acc)
    Accounts::ApiTokens::Issue.call(account: acc, organization:, name: "CLI").value[:secret]
  end

  it "senza bearer → 401" do
    get "/cli/v1/projects/#{project.id}/ideas"
    expect(response).to have_http_status(:unauthorized)
  end

  context "owner" do
    before { create(:membership, account:, organization:, role: :owner) }
    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    # CYRA-360 — l'ordine di default non è più per voti (il voto segnala interesse, non priorità):
    # è l'ultimo movimento, lo stesso della bacheca web.
    it "index → lista ordinata per ultimo movimento con envelope {data}" do
      stop = create(:idea, organization:, project:, title: "Ferma", created_at: 1.hour.ago, updated_at: 1.hour.ago)
      mossa = create(:idea, organization:, project:, title: "Mossa", created_at: 2.days.ago, updated_at: 2.days.ago)
      create(:idea_vote, idea: stop)
      mossa.touch

      get "/cli/v1/projects/#{project.id}/ideas", headers: headers

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data.map { |i| i["id"] }).to eq([ mossa.id, stop.id ])
      expect(data.first).to include("title" => "Mossa", "votes_count" => 0, "status" => "open")
    end

    it "index filtra per status" do
      create(:idea, organization:, project:, title: "Aperta")
      archived = create(:idea, :archived, organization:, project:, title: "Archiviata")

      get "/cli/v1/projects/#{project.id}/ideas", params: { status: "archived" }, headers: headers

      ids = response.parsed_body["data"].map { |i| i["id"] }
      expect(ids).to eq([ archived.id ])
    end

    it "show → dettaglio con author e backlink ticket" do
      idea = create(:idea, :converted, organization:, project:)

      get "/cli/v1/projects/#{project.id}/ideas/#{idea.id}", headers: headers

      data = response.parsed_body["data"]
      expect(data["status"]).to eq("converted")
      expect(data["ticket_id"]).to eq(idea.ticket_id)
      expect(data["author"]).to eq(idea.author.name)
    end

    it "show di un'idea di un ALTRO progetto → 404 (anti-BOLA)" do
      foreign = create(:idea, organization:)

      get "/cli/v1/projects/#{project.id}/ideas/#{foreign.id}", headers: headers

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body["error"]["code"]).to match(/^R404-/)
    end

    it "create → 201 con l'idea proposta (author = account del token)" do
      expect do
        post "/cli/v1/projects/#{project.id}/ideas",
             params: { title: "Dark mode", problem: "La dashboard acceca", solution: "Tema scuro",
                       stakeholders: [ "Team Mobile" ] }, headers: headers
      end.to change(Ideas::Idea, :count).by(1)

      expect(response).to have_http_status(:created)
      data = response.parsed_body["data"]
      expect(data["title"]).to eq("Dark mode")
      expect(data["problem"]).to eq("La dashboard acceca")
      expect(data["solution"]).to eq("Tema scuro")
      expect(data["stakeholders"]).to eq([ "Team Mobile" ])
      expect(data["author"]).to eq(account.name)
    end

    it "create con problema vuoto → 422 R422-IDEA-001 con details" do
      post "/cli/v1/projects/#{project.id}/ideas",
           params: { title: "x", problem: "" }, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      error = response.parsed_body["error"]
      expect(error["code"]).to eq("R422-IDEA-001")
      expect(error["details"]).to have_key("problem")
    end

    it "update → 200, l'owner riscrive un'idea altrui (full replace)" do
      idea = create(:idea, organization:, project:, title: "Vecchio", problem: "Vecchio problema",
                                                    solution: "Vecchia soluzione", stakeholders: [ "Team A" ])

      put "/cli/v1/projects/#{project.id}/ideas/#{idea.id}",
          params: { title: "Nuovo", problem: "Nuovo problema", solution: "Nuova soluzione",
                    stakeholders: [ "Team B", "Team C" ] }, headers: headers

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data).to include("title" => "Nuovo", "problem" => "Nuovo problema", "solution" => "Nuova soluzione")
      expect(data["stakeholders"]).to eq([ "Team B", "Team C" ])
    end

    it "update senza solution → svuota il campo (full replace)" do
      idea = create(:idea, organization:, project:, solution: "C'era una soluzione")

      put "/cli/v1/projects/#{project.id}/ideas/#{idea.id}",
          params: { title: "T", problem: "P" }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(idea.reload.solution).to be_blank
    end

    it "update su idea congelata → 422 R422-IDEA-002, contenuto invariato" do
      frozen = create(:idea, :converted, organization:, project:, title: "Originale")

      put "/cli/v1/projects/#{project.id}/ideas/#{frozen.id}",
          params: { title: "Cambiato", problem: "x" }, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-IDEA-002")
      expect(frozen.reload.title).to eq("Originale")
    end
  end

  context "member con accesso ma senza ideas.edit" do
    before do
      create(:membership, account:, organization:, role: :member)
      create(:project_membership, account:, project:)
    end
    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    it "update di un'idea altrui → 403, contenuto invariato" do
      idea = create(:idea, organization:, project:, title: "Originale")

      put "/cli/v1/projects/#{project.id}/ideas/#{idea.id}",
          params: { title: "Hack", problem: "x" }, headers: headers

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to match(/^R403-/)
      expect(idea.reload.title).to eq("Originale")
    end

    it "l'AUTORE aggiorna la propria idea anche senza ideas.edit → 200" do
      own = create(:idea, organization:, project:, author: account, title: "Mia")

      put "/cli/v1/projects/#{project.id}/ideas/#{own.id}",
          params: { title: "Mia aggiornata", problem: "Problema" }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(own.reload.title).to eq("Mia aggiornata")
    end
  end

  context "member senza accesso al progetto" do
    before { create(:membership, account:, organization:, role: :member) }
    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    it "index → 404 (progetto non visibile, strict scoping)" do
      get "/cli/v1/projects/#{project.id}/ideas", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE destroy (ideas.delete o autore)" do
    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    it "owner elimina → 204 e idea rimossa" do
      create(:membership, account:, organization:, role: :owner)
      idea = create(:idea, organization:, project:)

      delete "/cli/v1/projects/#{project.id}/ideas/#{idea.id}", params: { confirm: "1" }, headers: headers

      expect(response).to have_http_status(:no_content)
      expect(Ideas::Idea.exists?(idea.id)).to be(false)
    end

    it "member con accesso ma senza ideas.delete su idea altrui → 403, idea invariata" do
      create(:membership, account:, organization:, role: :member)
      create(:project_membership, account:, project:)
      idea = create(:idea, organization:, project:)

      delete "/cli/v1/projects/#{project.id}/ideas/#{idea.id}", headers: headers

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to match(/^R403-/)
      expect(Ideas::Idea.exists?(idea.id)).to be(true)
    end

    it "l'AUTORE elimina la propria idea anche senza ideas.delete → 204" do
      create(:membership, account:, organization:, role: :member)
      create(:project_membership, account:, project:)
      own = create(:idea, organization:, project:, author: account)

      delete "/cli/v1/projects/#{project.id}/ideas/#{own.id}", headers: headers

      expect(response).to have_http_status(:no_content)
      expect(Ideas::Idea.exists?(own.id)).to be(false)
    end

    it "idea di un altro progetto → 404 (anti-BOLA)" do
      create(:membership, account:, organization:, role: :owner)
      foreign = create(:idea, organization:)

      delete "/cli/v1/projects/#{project.id}/ideas/#{foreign.id}", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "archive singleton (ideas.edit o autore)" do
    before { create(:membership, account:, organization:, role: :owner) }
    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    it "PUT archivia un'idea aperta → 200 e status archived" do
      idea = create(:idea, organization:, project:) # open

      put "/cli/v1/projects/#{project.id}/ideas/#{idea.id}/archive", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["status"]).to eq("archived")
      expect(idea.reload.status).to eq("archived")
    end

    it "DELETE riapre un'idea archiviata → 200 e status open" do
      idea = create(:idea, :archived, organization:, project:)

      delete "/cli/v1/projects/#{project.id}/ideas/#{idea.id}/archive", headers: headers

      expect(response).to have_http_status(:ok)
      expect(idea.reload.status).to eq("open")
    end

    it "archiviare un'idea convertita (terminale) → 422 R422-IDEA-003" do
      converted = create(:idea, :converted, organization:, project:)

      put "/cli/v1/projects/#{project.id}/ideas/#{converted.id}/archive", headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-IDEA-003")
    end

    it "membro senza ideas.edit su idea altrui → 403" do
      other = create(:account)
      create(:membership, account: other, organization:, role: :member)
      create(:project_membership, account: other, project:)
      idea = create(:idea, organization:, project:)

      put "/cli/v1/projects/#{project.id}/ideas/#{idea.id}/archive",
          headers: { "Authorization" => "Bearer #{token_for(other)}" }

      expect(response).to have_http_status(:forbidden)
    end
  end
end
