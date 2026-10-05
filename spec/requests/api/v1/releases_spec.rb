# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Releases", type: :request do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:environment) { create(:environment, organization:, code: "production").tap { |e| project.environments << e } }
  let(:token) do
    Projects::Tokens::Issue.call(
      project:, name: "CI", host: "bugs.example.com", environment:
    ).value[:secret]
  end
  let(:headers) { { "Authorization" => "Bearer #{token}" } }

  describe "POST /api/v1/projects/:id/releases" do
    it "registra la release (version + sha + build_time) con l'environment DEL TOKEN → 201" do
      post "/api/v1/projects/#{project.id}/releases", headers:,
           params: { version: "v1.2.3", sha: "abc1234def", build_time: "2026-07-02T10:00:00Z" }

      expect(response).to have_http_status(:created)
      data = response.parsed_body["data"]
      expect(data["version"]).to eq("v1.2.3")
      expect(data["sha"]).to eq("abc1234def")
      expect(data["environment"]).to eq("production")
      release = project.releases.find_by!(version: "v1.2.3", environment: "production")
      expect(release.build_time).to eq(Time.utc(2026, 7, 2, 10))
    end

    it "l'environment lo detta il TOKEN, non il body (non falsificabile)" do
      post "/api/v1/projects/#{project.id}/releases", headers:,
           params: { version: "v1.2.3", environment: "production-hacked" }

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["data"]["environment"]).to eq("production")
      expect(project.releases.where(environment: "production-hacked")).to be_empty
    end

    it "stessa version, token di environment diverso → due release distinte" do
      staging = create(:environment, organization:, code: "staging").tap { |e| project.environments << e }
      staging_token = Projects::Tokens::Issue.call(
        project:, name: "CI staging", host: "bugs.example.com", environment: staging
      ).value[:secret]

      post "/api/v1/projects/#{project.id}/releases", headers:, params: { version: "v2.0.0" }
      post "/api/v1/projects/#{project.id}/releases",
           headers: { "Authorization" => "Bearer #{staging_token}" }, params: { version: "v2.0.0" }

      expect(project.releases.where(version: "v2.0.0").pluck(:environment)).to contain_exactly("production", "staging")
    end

    it "è idempotente per [project, version, environment]: la seconda chiamata aggiorna, non duplica" do
      post "/api/v1/projects/#{project.id}/releases", headers:, params: { version: "v1.2.3" }
      expect do
        post "/api/v1/projects/#{project.id}/releases", headers:,
             params: { version: "v1.2.3", sha: "abc1234" }
      end.not_to change(project.releases, :count)

      expect(project.releases.find_by!(version: "v1.2.3", environment: "production").sha).to eq("abc1234")
    end

    it "version blank → 422 R422-RELEASE-001" do
      post "/api/v1/projects/#{project.id}/releases", headers:, params: { version: "" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("R422-RELEASE-001")
    end

    it "build_time non parsabile → ignorata, release creata" do
      post "/api/v1/projects/#{project.id}/releases", headers:,
           params: { version: "v9", build_time: "boh" }

      expect(response).to have_http_status(:created)
      expect(project.releases.find_by!(version: "v9").build_time).to be_nil
    end

    it "senza token → 401" do
      post "/api/v1/projects/#{project.id}/releases", params: { version: "v1" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "token di un ALTRO progetto → 404 (anti-BOLA)" do
      other = create(:project, organization:)
      post "/api/v1/projects/#{other.id}/releases", headers:, params: { version: "v1" }
      expect(response).to have_http_status(:not_found)
    end

    it "con repo GitHub agganciato (tag_binding) marca la release come live per l'environment del deploy" do
      environment # forza creazione + dichiarazione dell'environment production del token
      create(:github_repository, project:,
                                 installation: create(:github_installation, organization:),
                                 production_environment: environment)

      post "/api/v1/projects/#{project.id}/releases", headers:, params: { version: "v3.0.0" }

      expect(response).to have_http_status(:created)
      expect(project.releases.find_by!(version: "v3.0.0", environment: "production")).to be_current
    end
  end

  describe "GET /api/v1/projects/:id/releases" do
    it "elenca le release recenti del progetto del token, con environment" do
      create(:release, project:, version: "v1.0.0", environment: "production")
      create(:release, project:, version: "v1.0.0", environment: "staging")
      create(:release) # altro progetto

      get "/api/v1/projects/#{project.id}/releases", headers: headers

      expect(response).to have_http_status(:ok)
      rows = response.parsed_body["data"].map { |r| [ r["version"], r["environment"] ] }
      expect(rows).to contain_exactly([ "v1.0.0", "production" ], [ "v1.0.0", "staging" ])
    end
  end

  # CYRA-607 — il timbro «questa versione l'ha vista qualcuno in piedi». Serve perché, quando
  # arriverà, la parola Fatto significhi che quella versione risponde in produzione e non che
  # qualcuno l'ha nominata.
  describe "il timbro della prova" do
    let(:sha) { "3f2a91c0d4e6b8079a1c5f3d2e7b4a6c8d0f1e29" }
    let!(:repository) { create(:github_repository, project:, production_environment_id: environment.id) }

    def record_outcome(**extra)
      post "/api/v1/projects/#{project.id}/releases", headers:, params: { version: "v1.4.0", sha:, **extra }
      project.releases.find_by(version: "v1.4.0", environment: "production")
    end

    it "timbra quando il chiamante dichiara di aver verificato, col codice e dall'ambiente di produzione" do
      expect(record_outcome(proved_at: "2026-08-21T10:00:00Z").proved_at).to be_present
    end

    # LA condizione che rende la cosa sicura oggi. La CI che verifica davvero legge /version dalla
    # produzione, confronta versione e codice, e solo allora registra: manda `proved_at`. Quella
    # vecchia registra dal lavoro che mette in linea, PRIMA di qualsiasi controllo, e `proved_at` non
    # lo manda. Senza questa condizione ogni repository ancora sulla CI vecchia — dieci su undici,
    # oggi — timbrerebbe una spia verde attaccata a un filo staccato.
    it "NON timbra una registrazione che non dichiara di aver verificato" do
      expect(record_outcome.proved_at).to be_nil
    end

    it "NON timbra senza il codice: un timbro senza sigla non si confronta con niente" do
      post "/api/v1/projects/#{project.id}/releases", headers:,
           params: { version: "v1.9.0", proved_at: "2026-08-21T10:00:00Z" }

      expect(project.releases.find_by(version: "v1.9.0").proved_at).to be_nil
    end

    it "l'ora la mette il server: quella dichiarata dal chiamante non si legge" do
      riga = record_outcome(proved_at: "1999-01-01T00:00:00Z")

      expect(riga.proved_at).to be > 1.hour.ago
    end

    context "quando il token è di un ambiente che non è la produzione del repository" do
      let(:environment) { create(:environment, organization:, code: "staging").tap { |e| project.environments << e } }
      let!(:repository) do
        create(:github_repository, project:,
                                   production_environment_id: create(:environment, organization:, code: "production")
                                     .tap { |e| project.environments << e }.id)
      end

      it "non timbra: sullo staging il timbro sarebbe una spia verde su un filo staccato" do
        post "/api/v1/projects/#{project.id}/releases", headers:,
             params: { version: "v1.4.0", sha:, proved_at: "2026-08-21T10:00:00Z" }

        expect(project.releases.find_by(version: "v1.4.0", environment: "staging").proved_at).to be_nil
      end
    end

    context "quando il progetto non ha nessun repository agganciato" do
      let!(:repository) { nil }

      it "non timbra: non c'è nessuna produzione dichiarata da confrontare" do
        expect(record_outcome(proved_at: "2026-08-21T10:00:00Z").proved_at).to be_nil
      end
    end
  end
end
