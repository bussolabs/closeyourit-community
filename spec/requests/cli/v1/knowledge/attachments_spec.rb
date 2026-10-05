# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Knowledge::Attachments", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:page_kb) { create(:knowledge_page, organization:, project:, created_by: account) }

  before { create(:membership, account:, organization:, role: :owner) }

  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  # Membro che VEDE il progetto ma senza chiavi knowledge.* → testa il 403 sulle pagine altrui.
  def member_headers
    member = create(:account)
    create(:membership, account: member, organization:, role: :member)
    create(:project_membership, account: member, project:)
    member_secret = Accounts::ApiTokens::Issue.call(account: member, organization:, name: "CLI").value[:secret]
    { "Authorization" => "Bearer #{member_secret}" }
  end

  def upload(name, declared_type)
    Rack::Test::UploadedFile.new(Rails.root.join("spec/fixtures/files/#{name}"), declared_type)
  end

  it "senza token → 401" do
    get "/cli/v1/knowledge/pages/#{page_kb.id}/attachments"
    expect(response).to have_http_status(:unauthorized)
  end

  describe "GET index" do
    it "elenca i metadati degli allegati, marcando gli script" do
      Knowledge::Attachments::Upload.call(page: page_kb, files: [ upload("script.sh", "application/x-sh") ],
                                          actor: account)

      get "/cli/v1/knowledge/pages/#{page_kb.id}/attachments", headers: headers

      expect(response).to have_http_status(:ok)
      riga = response.parsed_body["data"].sole
      expect(riga).to include("title" => "script.sh", "content_type" => "application/x-sh", "script" => true)
      # Mai un URL firmato nel payload: il binario si prende dall'endpoint download.
      expect(riga.keys).not_to include("url", "signed_id")
    end
  end

  describe "POST create" do
    it "carica un file e ritorna 201" do
      expect do
        post "/cli/v1/knowledge/pages/#{page_kb.id}/attachments",
             params: { files: [ upload("script.sh", "application/x-sh") ] }, headers: headers
      end.to change(Knowledge::Attachment, :count).by(1)

      expect(response).to have_http_status(:created)
    end

    it "rifiuta una pagina web con R422-KNOWLEDGE-008" do
      post "/cli/v1/knowledge/pages/#{page_kb.id}/attachments",
           params: { files: [ upload("payload.html", "text/html") ] }, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("R422-KNOWLEDGE-008")
    end

    it "rifiuta un file travestito, sniffando i byte reali" do
      post "/cli/v1/knowledge/pages/#{page_kb.id}/attachments",
           params: { files: [ upload("payload.html", "image/png") ] }, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(Knowledge::Attachment.count).to eq(0)
    end

    it "nega a chi vede la pagina ma non può modificarla" do
      altrui = create(:knowledge_page, organization:, project:, created_by: account)

      post "/cli/v1/knowledge/pages/#{altrui.id}/attachments",
           params: { files: [ upload("notes.txt", "text/plain") ] }, headers: member_headers

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "code")).to eq("R403-CLIAUTH-002")
    end

    it "404 su una pagina non visibile" do
      estranea = create(:knowledge_page, organization:, project: create(:project, organization:))

      post "/cli/v1/knowledge/pages/#{estranea.id}/attachments",
           params: { files: [ upload("notes.txt", "text/plain") ] }, headers: member_headers

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET download" do
    let!(:attachment) do
      Knowledge::Attachments::Upload.call(page: page_kb, files: [ upload("script.sh", "application/x-sh") ],
                                          actor: account).value.first
    end

    it "consegna il binario come file da salvare, non col suo tipo reale" do
      get "/cli/v1/knowledge/pages/#{page_kb.id}/attachments/#{attachment.id}/download", headers: member_headers

      expect(response).to have_http_status(:ok)
      expect(response.headers["Content-Type"]).to eq("application/octet-stream")
      expect(response.headers["Content-Disposition"]).to start_with("attachment")
      expect(response.headers["X-Content-Type-Options"]).to eq("nosniff")
      expect(response.body).to include("echo")
    end
  end

  describe "DELETE destroy" do
    let!(:attachment) { create(:knowledge_attachment, page: page_kb, created_by: account) }

    it "elimina e risponde 204" do
      expect do
        delete "/cli/v1/knowledge/pages/#{page_kb.id}/attachments/#{attachment.id}", headers: headers
      end.to change(Knowledge::Attachment, :count).by(-1)

      expect(response).to have_http_status(:no_content)
    end

    it "nega a chi non può modificare la pagina" do
      expect do
        delete "/cli/v1/knowledge/pages/#{page_kb.id}/attachments/#{attachment.id}", headers: member_headers
      end.not_to change(Knowledge::Attachment, :count)

      expect(response).to have_http_status(:forbidden)
    end
  end
end
