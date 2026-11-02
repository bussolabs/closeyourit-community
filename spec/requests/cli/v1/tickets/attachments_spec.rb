# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Tickets::Attachments", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:ticket) { create(:ticket, project:, organization:) }

  before { create(:membership, account:, organization:, role: :owner) }

  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }
  let(:attachments_path) { "/cli/v1/projects/#{project.id}/tickets/#{ticket.id}/attachments" }

  # Membro che VEDE il progetto (project_membership) ma senza tickets.attachments.manage → testa il 403.
  def member_headers
    member = create(:account)
    create(:membership, account: member, organization:, role: :member)
    create(:project_membership, account: member, project:)
    member_secret = Accounts::ApiTokens::Issue.call(account: member, organization:, name: "CLI").value[:secret]
    { "Authorization" => "Bearer #{member_secret}" }
  end

  it "senza bearer → 401" do
    post attachments_path, params: { files: [ fixture_file_upload("screenshot.png", "image/png") ] }
    expect(response).to have_http_status(:unauthorized)
  end

  describe "POST create (gate tickets.attachments.manage)" do
    it "owner allega un file → 201, allegato aggiunto e lista in risposta" do
      expect do
        post attachments_path, headers: headers,
                               params: { files: [ fixture_file_upload("screenshot.png", "image/png") ] }
      end.to change { ticket.reload.files.count }.by(1)

      expect(response).to have_http_status(:created)
      data = response.parsed_body["data"]
      expect(data).to be_an(Array)
      expect(data.first).to include("filename", "byte_size", "content_type")
      expect(data.first["filename"]).to eq("screenshot.png")
    end

    it "tipo non ammesso (svg) → 422 R422-ATTACHMENT-001, nessun allegato" do
      post attachments_path, headers: headers,
                             params: { files: [ fixture_file_upload("diagram.svg", "image/svg+xml") ] }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-ATTACHMENT-001")
      expect(ticket.reload.files).not_to be_attached
    end

    it "nessun file → 422 R422-ATTACHMENT-001" do
      post attachments_path, headers: headers, params: {}

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-ATTACHMENT-001")
      expect(ticket.reload.files).not_to be_attached
    end

    it "ticket di un progetto di un'altra org → 404 (anti-BOLA, set_project!)" do
      foreign = create(:ticket, organization: create(:organization))

      post "/cli/v1/projects/#{foreign.project_id}/tickets/#{foreign.id}/attachments", headers: headers,
           params: { files: [ fixture_file_upload("screenshot.png", "image/png") ] }

      expect(response).to have_http_status(:not_found)
    end

    it "membro che vede il progetto ma senza tickets.attachments.manage → 403 e nessun allegato" do
      post attachments_path, headers: member_headers,
                             params: { files: [ fixture_file_upload("screenshot.png", "image/png") ] }

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
      expect(ticket.reload.files).not_to be_attached
    end
  end

  describe "DELETE destroy (gate tickets.attachments.manage)" do
    it "owner rimuove un allegato → 204 e file rimosso" do
      ticket.files.attach(fixture_file_upload("screenshot.png", "image/png"))
      attachment = ticket.files.first

      expect do
        delete "#{attachments_path}/#{attachment.id}", headers: headers
      end.to change { ticket.reload.files.count }.by(-1)

      expect(response).to have_http_status(:no_content)
    end

    it "membro che vede il progetto ma senza tickets.attachments.manage → 403 e allegato invariato" do
      ticket.files.attach(fixture_file_upload("screenshot.png", "image/png"))
      attachment = ticket.files.first

      delete "#{attachments_path}/#{attachment.id}", headers: member_headers

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
      expect(ticket.reload.files).to be_attached
    end
  end

  describe "GET index (lettura, baseline — NON gated)" do
    it "senza bearer → 401" do
      get attachments_path
      expect(response).to have_http_status(:unauthorized)
    end

    it "owner lista gli allegati con metadati + meta" do
      ticket.files.attach(fixture_file_upload("screenshot.png", "image/png"))

      get attachments_path, headers: headers

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data).to be_an(Array)
      expect(data.first["filename"]).to eq("screenshot.png")
      expect(data.first).to include("byte_size", "content_type")
      expect(response.parsed_body["meta"]).to include("page", "per", "total", "total_pages")
    end

    it "member che vede il progetto (senza attachments.manage) legge → 200 (baseline)" do
      ticket.files.attach(fixture_file_upload("screenshot.png", "image/png"))

      get attachments_path, headers: member_headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"].size).to eq(1)
    end

    it "ticket di un'altra org → 404 (anti-BOLA)" do
      foreign = create(:ticket, organization: create(:organization))
      get "/cli/v1/projects/#{foreign.project_id}/tickets/#{foreign.id}/attachments", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  # CYRA-1121 — il file arriva dall'app subito dopo il controllo di visibilità, mai da un rimando a un
  # link dello storage (che si aprirebbe senza ricontrollare chi lo usa).
  describe "GET download (baseline — file inviato dopo il controllo)" do
    let(:png) { File.binread(file_fixture("screenshot.png")) }

    def expect_file_delivered
      expect(response).to have_http_status(:ok)
      expect(response.location).to be_nil
      expect(response.body.b).to eq(png.b)
      expect(response.media_type).to eq("application/octet-stream")
      expect(response.headers["Content-Disposition"]).to include("attachment", "screenshot.png")
      expect(response.headers["X-Content-Type-Options"]).to eq("nosniff")
    end

    it "owner scarica → riceve il file, senza redirect" do
      ticket.files.attach(fixture_file_upload("screenshot.png", "image/png"))
      attachment = ticket.files.first

      get "#{attachments_path}/#{attachment.id}/download", headers: headers

      expect_file_delivered
    end

    it "SC-7: chi vede il progetto riceve il file, chi non lo vede più riceve 404" do
      ticket.files.attach(fixture_file_upload("screenshot.png", "image/png"))
      attachment = ticket.files.first
      reader = member_headers
      outsider = create(:account)
      create(:membership, account: outsider, organization:, role: :member)
      outsider_secret = Accounts::ApiTokens::Issue.call(account: outsider, organization:, name: "CLI").value[:secret]

      get "#{attachments_path}/#{attachment.id}/download", headers: reader
      expect_file_delivered

      get "#{attachments_path}/#{attachment.id}/download", headers: { "Authorization" => "Bearer #{outsider_secret}" }
      expect(response).to have_http_status(:not_found)
      expect(response.body.b).not_to include(png.b)
    end

    it "SC-7: lo STESSO token smette di scaricare appena il membro viene tolto dal progetto" do
      ticket.files.attach(fixture_file_upload("screenshot.png", "image/png"))
      attachment = ticket.files.first
      reader = member_headers
      download_path = "#{attachments_path}/#{attachment.id}/download"

      get download_path, headers: reader
      expect_file_delivered

      Connections::ProjectMembership.where(project:).destroy_all
      get download_path, headers: reader

      expect(response).to have_http_status(:not_found)
      expect(response.location).to be_nil
      expect(response.body.b).not_to include(png.b)
    end

    it "file di un COMMENTO del ticket → file inviato (unico endpoint per tutti i binari del ticket)" do
      comment = create(:ticket_comment, ticket:, organization:)
      comment.files.attach(fixture_file_upload("screenshot.png", "image/png"))
      attachment = comment.files_attachments.first

      get "#{attachments_path}/#{attachment.id}/download", headers: headers

      expect_file_delivered
    end

    it "file di un commento di un ALTRO ticket → 404 (lookup scoped al ticket, anti-BOLA)" do
      other_ticket = create(:ticket, project:, organization:)
      comment = create(:ticket_comment, ticket: other_ticket, organization:)
      comment.files.attach(fixture_file_upload("screenshot.png", "image/png"))
      attachment = comment.files_attachments.first

      get "#{attachments_path}/#{attachment.id}/download", headers: headers

      expect(response).to have_http_status(:not_found)
    end

    it "download via code umano del ticket → file inviato (i sub-endpoint accettano lo stesso ref dello show)" do
      ticket.files.attach(fixture_file_upload("screenshot.png", "image/png"))
      attachment = ticket.files.first

      get "/cli/v1/projects/#{project.id}/tickets/#{ticket.code}/attachments/#{attachment.id}/download",
          headers: headers

      expect_file_delivered
    end
  end
end
