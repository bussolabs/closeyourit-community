# frozen_string_literal: true

require "rails_helper"

# CYRA-718 — contratto UNICO delle risposte di errore dei canali macchina (API a token di progetto e
# riga di comando). Due cose vanno insieme e per questo stanno in un file solo:
#
#   1. un dato di un'altra organizzazione deve rispondere ESATTAMENTE come un dato inesistente
#      (anti-BOLA: la differenza fra i due, anche solo nel codice o nel messaggio, confermerebbe che
#      quel dato esiste);
#   2. la forma dell'errore deve essere la stessa su tutti i canali — envelope
#      `{ error: { code, message } }` — anche quando l'errore non nasce dal codice di dominio ma dal
#      framework (corpo illeggibile, parametro obbligatorio assente). Lì la richiesta finiva
#      sull'exceptions_app, che rende una PAGINA HTML: un client che fa il parse del JSON riceve una
#      cosa che non sa leggere, al posto dell'errore che gli serviva.
RSpec.describe "Contratto delle risposte di errore dei canali macchina", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:cli_secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:cli_headers) { { "Authorization" => "Bearer #{cli_secret}" } }
  let(:json_headers) { cli_headers.merge("CONTENT_TYPE" => "application/json") }

  before { create(:membership, account:, organization:, role: :owner) }

  describe "una sola implementazione per tutti i canali" do
    it "le due basi JSON condividono lo stesso contratto (ApiEnvelope), non due copie gemelle" do
      expect(Api::BaseController.include?(ApiEnvelope)).to be(true)
      expect(Cli::Api::BaseController.include?(ApiEnvelope)).to be(true)
    end

    it "il contratto porta con sé la resa degli errori su entrambi i canali" do
      expect(Api::BaseController.include?(ErrorRendering)).to be(true)
      expect(Cli::Api::BaseController.include?(ErrorRendering)).to be(true)
    end
  end

  describe "riga di comando — dato non proprio" do
    it "un dato di un'altra organizzazione risponde come un dato inesistente" do
      other = create(:group) # gruppo di un'altra organizzazione

      get "/cli/v1/groups/#{other.id}", headers: cli_headers
      foreign = [ response.status, response.parsed_body ]

      get "/cli/v1/groups/#{SecureRandom.uuid}", headers: cli_headers
      missing = [ response.status, response.parsed_body ]

      expect(foreign).to eq(missing)
      expect(foreign.first).to eq(404)
      expect(foreign.last).to eq("error" => { "code" => "R404-SYSTEM-001", "message" => "Risorsa non trovata" })
    end
  end

  describe "riga di comando — errori del framework" do
    it "corpo della richiesta illeggibile → envelope R400-SYSTEM-001, non una pagina" do
      post "/cli/v1/groups", headers: json_headers, params: '{ "name": '

      expect(response).to have_http_status(:bad_request)
      expect(response.media_type).to eq("application/json")
      expect(response.parsed_body["error"]["code"]).to eq("R400-SYSTEM-001")
    end

    it "parametro obbligatorio assente → envelope R422-SYSTEM-002, non una pagina" do
      post "/cli/v1/projects/#{project.id}/tokens/provisions", headers: cli_headers, params: { confirm: "1", name: "senza destinazione" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.media_type).to eq("application/json")
      expect(response.parsed_body["error"]).to include("code" => "R422-SYSTEM-002")
    end

    # La delega ripetuta dello stesso file allo stesso progetto è l'unica validazione che il canale
    # non gestisce sul posto: arriva al fallback. `details` deve avere la stessa forma degli altri
    # 422 di validazione (`errors.to_hash`, campo → messaggi), altrimenti chi legge la risposta deve
    # sapere in anticipo QUALE errore ha ricevuto per capire come è fatto il campo details.
    it "validazione fallita → envelope R422-SYSTEM-001 con details campo → messaggi" do
      ENV["SECRET_ASSETS_MASTER_KEY"] = Base64.strict_encode64("k" * 32)
      post "/cli/v1/shared_secret_assets", headers: cli_headers, params: { confirm: "1", name: "Distribution", file: p8_upload }
      asset_id = response.parsed_body.dig("data", "id")
      post "/cli/v1/shared_secret_assets/#{asset_id}/delegate", headers: cli_headers, params: { confirm: "1", project_id: project.id }
      expect(response).to have_http_status(:created)

      post "/cli/v1/shared_secret_assets/#{asset_id}/delegate", headers: cli_headers, params: { confirm: "1", project_id: project.id }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.media_type).to eq("application/json")
      expect(response.parsed_body["error"]["code"]).to eq("R422-SYSTEM-001")
      details = response.parsed_body.dig("error", "details")
      expect(details.keys).to eq([ "project_id" ])
      expect(details["project_id"]).to be_an(Array).and be_present
    ensure
      ENV.delete("SECRET_ASSETS_MASTER_KEY")
    end
  end

  describe "API a token di progetto — stessa forma della riga di comando" do
    let(:environment) { create(:environment, organization:).tap { |e| project.environments << e } }
    let(:api_secret) do
      Projects::Tokens::Issue.call(project:, name: "SDK", host: "bugs.example.com",
                                   environment:).value[:secret]
    end
    let(:api_headers) { { "Authorization" => "Bearer #{api_secret}" } }

    it "un dato di un altro progetto risponde come un dato inesistente" do
      foreign_group = create(:error_group, project: create(:project, organization: create(:organization)))

      get "/api/v1/error_groups/#{foreign_group.id}", headers: api_headers
      foreign = [ response.status, response.parsed_body ]

      get "/api/v1/error_groups/#{SecureRandom.uuid}", headers: api_headers
      missing = [ response.status, response.parsed_body ]

      expect(foreign).to eq(missing)
      expect(foreign.last).to eq("error" => { "code" => "R404-SYSTEM-001", "message" => "Risorsa non trovata" })
    end

    it "corpo illeggibile → lo stesso envelope della riga di comando" do
      put "/api/v1/error_groups/#{SecureRandom.uuid}/resolution",
          headers: api_headers.merge("CONTENT_TYPE" => "application/json"), params: '{ "note": '
      api_body = response.parsed_body
      api_status = response.status

      post "/cli/v1/groups", headers: json_headers, params: '{ "name": '

      expect([ api_status, api_body ]).to eq([ response.status, response.parsed_body ])
    end

    it "l'ingest conserva il proprio codice specifico (il canale non lo perde per l'unificazione)" do
      post "/api/v1/projects/#{project.id}/logs",
           headers: api_headers.merge("CONTENT_TYPE" => "application/json"), params: '{ "entries": '

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-LOG-001")
    end
  end

  def p8_upload
    file = Tempfile.new([ "Distribution", ".p8" ])
    file.write("-----BEGIN PRIVATE KEY-----\ntest-only\n-----END PRIVATE KEY-----")
    file.rewind
    Rack::Test::UploadedFile.new(file.path, "application/octet-stream", original_filename: "Distribution.p8")
  end
end
