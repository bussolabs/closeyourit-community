# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Tickets::Comments", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:ticket) { create(:ticket, project:, organization:) }

  def token_for(acc)
    Accounts::ApiTokens::Issue.call(account: acc, organization:, name: "CLI").value[:secret]
  end

  it "senza bearer → 401" do
    create(:membership, account:, organization:, role: :owner)
    post "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/comments", params: { body: "ciao" }
    expect(response).to have_http_status(:unauthorized)
  end

  context "owner (vede tutto + tickets.comment.delete_any)" do
    before { create(:membership, account:, organization:, role: :owner) }
    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    it "create → 201 con il commento serializzato" do
      expect do
        post "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/comments",
             headers: headers, params: { body: "Confermo il bug" }
      end.to change(Ticketing::Comment, :count).by(1)

      expect(response).to have_http_status(:created)
      data = response.parsed_body["data"]
      expect(data["body"]).to eq("Confermo il bug")
      expect(data["author"]).to eq(account.name)
      expect(data["ticket_id"]).to eq(ticket.id)
    end

    it "create con body blank → 422 R422-COMMENT-001" do
      post "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/comments",
           headers: headers, params: { body: "   " }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-COMMENT-001")
    end

    it "create oltre i 240 caratteri → 422 R422-COMMENT-002 che indirizza al resoconto" do
      post "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/comments",
           headers: headers, params: { body: "x" * (Ticketing::Constants::COMMENT_MAX_CHARS + 1) }

      expect(response).to have_http_status(:unprocessable_content)
      error = response.parsed_body["error"]
      expect(error["code"]).to eq("R422-COMMENT-002")
      expect(error["message"]).to include("240")
      expect(error["details"]["body"]).to be_present
    end

    it "create esattamente a 240 caratteri → 201" do
      post "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/comments",
           headers: headers, params: { body: "x" * Ticketing::Constants::COMMENT_MAX_CHARS }

      expect(response).to have_http_status(:created)
    end

    it "destroy del proprio commento → 204" do
      comment = create(:ticket_comment, ticket:, organization:, author: account)
      expect do
        delete "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/comments/#{comment.id}", headers: headers
      end.to change(Ticketing::Comment, :count).by(-1)
      expect(response).to have_http_status(:no_content)
    end

    it "destroy del commento altrui → 204 (owner ha tickets.comment.delete_any)" do
      other = create(:account)
      create(:membership, account: other, organization:, role: :member)
      comment = create(:ticket_comment, ticket:, organization:, author: other)

      delete "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/comments/#{comment.id}", params: { confirm: "1" }, headers: headers
      expect(response).to have_http_status(:no_content)
      expect(Ticketing::Comment).not_to exist(comment.id)
    end

    it "commento di un altro ticket → 404 (anti-BOLA)" do
      other_ticket = create(:ticket, project:, organization:)
      comment = create(:ticket_comment, ticket: other_ticket, organization:, author: account)
      delete "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/comments/#{comment.id}", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "ticket di un'altra org → 404 (anti-BOLA)" do
      other = create(:ticket, organization: create(:organization))
      post "/cli/v1/projects/#{other.project_id}/tickets/#{other.id}/comments",
           headers: headers, params: { body: "x" }
      expect(response).to have_http_status(:not_found)
    end
  end

  context "member che vede il progetto (baseline: commenta)" do
    before do
      create(:membership, account:, organization:, role: :member)
      create(:project_membership, account:, project:)
    end
    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    it "può commentare → 201" do
      post "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/comments",
           headers: headers, params: { body: "Anch'io lo vedo" }
      expect(response).to have_http_status(:created)
    end

    it "può eliminare il PROPRIO commento → 204" do
      comment = create(:ticket_comment, ticket:, organization:, author: account)
      delete "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/comments/#{comment.id}", headers: headers
      expect(response).to have_http_status(:no_content)
    end

    it "NON può eliminare il commento altrui senza tickets.comment.delete_any → 403 R403-CLIAUTH-002" do
      other = create(:account)
      create(:membership, account: other, organization:, role: :member)
      comment = create(:ticket_comment, ticket:, organization:, author: other)

      expect do
        delete "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/comments/#{comment.id}", headers: headers
      end.not_to change(Ticketing::Comment, :count)

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
    end
  end

  context "member che NON vede il progetto (strict Fase E)" do
    before { create(:membership, account:, organization:, role: :member) }
    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    it "non vede il progetto → 404 (anti-BOLA)" do
      post "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/comments",
           headers: headers, params: { body: "x" }
      expect(response).to have_http_status(:not_found)
    end
  end

  context "index — lettura commenti (baseline: chi vede il ticket)" do
    it "senza bearer → 401" do
      get "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/comments"
      expect(response).to have_http_status(:unauthorized)
    end

    context "owner" do
      before { create(:membership, account:, organization:, role: :owner) }
      let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

      it "lista i commenti in ordine cronologico con envelope + meta" do
        c1 = create(:ticket_comment, ticket:, organization:, author: account, body: "primo")
        c2 = create(:ticket_comment, ticket:, organization:, author: account, body: "secondo")

        get "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/comments", headers: headers

        expect(response).to have_http_status(:ok)
        data = response.parsed_body["data"]
        expect(data.map { |c| c["id"] }).to eq([ c1.id, c2.id ])
        expect(data.first).to include("body" => "primo", "author" => account.name, "ticket_id" => ticket.id)
        expect(response.parsed_body["meta"]).to include("page", "per", "total", "total_pages")
        expect(response.parsed_body["meta"]["total"]).to eq(2)
      end

      it "ticket senza commenti → data vuoto" do
        get "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/comments", headers: headers
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["data"]).to eq([])
      end

      it "espone i files del commento (immagini) con metadati, mai URL" do
        comment = create(:ticket_comment, ticket:, organization:, author: account)
        comment.files.attach(fixture_file_upload("screenshot.png", "image/png"))

        get "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/comments", headers: headers

        files = response.parsed_body["data"].first["files"]
        expect(files.size).to eq(1)
        expect(files.first).to include("filename" => "screenshot.png", "content_type" => "image/png")
        expect(files.first).to include("id", "byte_size", "created_at")
        expect(files.first).not_to have_key("url")
      end

      it "commento senza allegati → files vuoto" do
        create(:ticket_comment, ticket:, organization:, author: account)

        get "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/comments", headers: headers

        expect(response.parsed_body["data"].first["files"]).to eq([])
      end

      it "index via code umano del ticket → 200 (i sub-endpoint accettano lo stesso ref dello show)" do
        create(:ticket_comment, ticket:, organization:, author: account, body: "via code")

        get "/cli/v1/projects/#{project.id}/tickets/#{ticket.code}/comments", headers: headers

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["data"].first["body"]).to eq("via code")
      end
    end

    it "member che vede il progetto legge i commenti → 200 (baseline)" do
      member = create(:account)
      create(:membership, account: member, organization:, role: :member)
      create(:project_membership, account: member, project:)
      create(:ticket_comment, ticket:, organization:, author: member, body: "x")
      secret = Accounts::ApiTokens::Issue.call(account: member, organization:, name: "CLI").value[:secret]

      get "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/comments",
          headers: { "Authorization" => "Bearer #{secret}" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"].size).to eq(1)
    end

    it "member che NON vede il progetto → 404 (anti-BOLA)" do
      create(:membership, account:, organization:, role: :member)
      get "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/comments",
          headers: { "Authorization" => "Bearer #{token_for(account)}" }
      expect(response).to have_http_status(:not_found)
    end

    it "ticket di un'altra org → 404 (anti-BOLA)" do
      create(:membership, account:, organization:, role: :owner)
      other = create(:ticket, organization: create(:organization))
      get "/cli/v1/projects/#{other.project_id}/tickets/#{other.id}/comments",
          headers: { "Authorization" => "Bearer #{token_for(account)}" }
      expect(response).to have_http_status(:not_found)
    end
  end
end
