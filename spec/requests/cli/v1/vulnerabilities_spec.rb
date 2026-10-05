# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Vulnerabilities", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }

  def token_for(acc)
    Accounts::ApiTokens::Issue.call(account: acc, organization:, name: "CLI").value[:secret]
  end

  # Un finding nasce da un manifest: il progetto è quello del manifest, non un attributo libero.
  # Il path va variato perché è unico per progetto, e qui ne servono più d'uno sullo stesso.
  def finding_for(target_project, advisory_trait: nil, **attrs)
    manifest = create(:vulnerability_manifest, project: target_project, path: "Gemfile-#{SecureRandom.hex(4)}.lock")
    package = create(:vulnerability_package, manifest:)
    advisory = advisory_trait ? create(:vulnerability_advisory, advisory_trait) : create(:vulnerability_advisory)
    create(:vulnerability_finding, package:, advisory:, project: target_project, **attrs)
  end

  it "senza bearer → 401" do
    create(:membership, account:, organization:, role: :owner)
    get "/cli/v1/vulnerabilities"
    expect(response).to have_http_status(:unauthorized)
  end

  context "owner (vede tutto + triage)" do
    before { create(:membership, account:, organization:, role: :owner) }
    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    it "index → 200 con i finding dei progetti visibili e meta" do
      finding = finding_for(project)
      get "/cli/v1/vulnerabilities", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"].map { |f| f["id"] }).to include(finding.id)
      expect(response.parsed_body["meta"]).to include("total")
    end

    # È la ragione d'essere del comando: una sola chiamata vede la flotta intera.
    it "index è cross-progetto: senza project_id arrivano i finding di TUTTI i progetti visibili" do
      altro = create(:project, organization:)
      qui = finding_for(project)
      la = finding_for(altro)

      get "/cli/v1/vulnerabilities", headers: headers

      expect(response.parsed_body["data"].map { |f| f["id"] }).to include(qui.id, la.id)
    end

    it "index con project_id filtra su quel progetto" do
      altro = create(:project, organization:)
      qui = finding_for(project)
      la = finding_for(altro)

      get "/cli/v1/vulnerabilities", params: { project_id: project.id }, headers: headers

      ids = response.parsed_body["data"].map { |f| f["id"] }
      expect(ids).to include(qui.id)
      expect(ids).not_to include(la.id)
    end

    it "index ordina per gravità decrescente (la lettura parte da ciò che fa più male)" do
      finding_for(project, advisory_trait: :low)
      finding_for(project, advisory_trait: :critical)

      get "/cli/v1/vulnerabilities", headers: headers

      severities = response.parsed_body["data"].map { |f| f["advisory"]["severity"] }
      expect(severities.first).to eq("critical")
    end

    it "index filtra per status quando il param è valido" do
      aperta = finding_for(project)
      ignorata = finding_for(project, status: :ignored)

      get "/cli/v1/vulnerabilities", params: { status: "ignored" }, headers: headers

      ids = response.parsed_body["data"].map { |f| f["id"] }
      expect(ids).to include(ignorata.id)
      expect(ids).not_to include(aperta.id)
    end

    it "index filtra per severity quando il param è valido" do
      critica = finding_for(project, advisory_trait: :critical)
      bassa = finding_for(project, advisory_trait: :low)

      get "/cli/v1/vulnerabilities", params: { severity: "critical" }, headers: headers

      ids = response.parsed_body["data"].map { |f| f["id"] }
      expect(ids).to include(critica.id)
      expect(ids).not_to include(bassa.id)
    end

    # Un valore fuori vocabolario è un filtro che non esiste, non una richiesta malformata: si ignora
    # e si restituisce tutto, come fa il canale Member.
    it "index con status o severity inventati ignora il filtro invece di dare 400" do
      finding = finding_for(project)

      get "/cli/v1/vulnerabilities", params: { status: "banana", severity: "apocalittica" }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"].map { |f| f["id"] }).to include(finding.id)
    end

    it "index filtra per nome pacchetto (ILIKE parziale)" do
      manifest = create(:vulnerability_manifest, project:)
      cercato = create(:vulnerability_finding,
                       package: create(:vulnerability_package, manifest:, name: "nokogiri"), project:)
      altro = create(:vulnerability_finding,
                     package: create(:vulnerability_package, manifest:, name: "rack"), project:)

      get "/cli/v1/vulnerabilities", params: { package: "noko" }, headers: headers

      ids = response.parsed_body["data"].map { |f| f["id"] }
      expect(ids).to include(cercato.id)
      expect(ids).not_to include(altro.id)
    end

    it "show → 200 con advisory, pacchetto e manifest (quello che serve per decidere)" do
      finding = finding_for(project)
      get "/cli/v1/vulnerabilities/#{finding.id}", headers: headers

      data = response.parsed_body["data"]
      expect(data["id"]).to eq(finding.id)
      expect(data["package"]).to include("name", "version", "ecosystem", "coordinates")
      expect(data["advisory"]).to include("osv_id", "display_id", "severity", "url")
      expect(data["manifest"]["path"]).to eq(finding.package.manifest.path)
      expect(data["project"]).to include("id", "key", "name")
    end

    it "finding di un'altra organizzazione → 404 (anti-BOLA)" do
      estraneo = finding_for(create(:project))
      get "/cli/v1/vulnerabilities/#{estraneo.id}", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "project_id di un'altra organizzazione → 404 (anti-BOLA)" do
      get "/cli/v1/vulnerabilities", params: { project_id: create(:project).id }, headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "runtimes → 200 con gli stati di supporto dei progetti visibili" do
      runtime = create(:vulnerability_runtime_status, :eol, project:)
      get "/cli/v1/vulnerabilities/runtimes", headers: headers

      expect(response).to have_http_status(:ok)
      riga = response.parsed_body["data"].find { |r| r["id"] == runtime.id }
      expect(riga).to include("name" => runtime.name, "state" => "eol")
      expect(riga["project"]).to include("key")
    end

    it "runtimes con project_id filtra su quel progetto" do
      altro = create(:project, organization:)
      qui = create(:vulnerability_runtime_status, project:)
      la = create(:vulnerability_runtime_status, project: altro)

      get "/cli/v1/vulnerabilities/runtimes", params: { project_id: project.id }, headers: headers

      ids = response.parsed_body["data"].map { |r| r["id"] }
      expect(ids).to include(qui.id)
      expect(ids).not_to include(la.id)
    end

    it "rescan accoda la scansione del progetto" do
      expect do
        post "/cli/v1/vulnerabilities/rescan", params: { project_id: project.id }, headers: headers
      end.to have_enqueued_job(Vulnerabilities::ScanProjectJob).with(project.id)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]).to include("project_id" => project.id, "scan" => "queued")
    end

    it "rescan su un progetto di un'altra organizzazione → 404, nessun job accodato" do
      expect do
        post "/cli/v1/vulnerabilities/rescan", params: { project_id: create(:project).id }, headers: headers
      end.not_to have_enqueued_job(Vulnerabilities::ScanProjectJob)

      expect(response).to have_http_status(:not_found)
    end
  end

  context "member che vede il progetto ma senza vulnerabilities.triage" do
    before do
      create(:membership, account:, organization:, role: :member)
      create(:project_membership, account:, project:)
    end
    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    it "può leggere: la visibilità del progetto è il gate, non una chiave" do
      finding_for(project)
      get "/cli/v1/vulnerabilities", headers: headers
      expect(response).to have_http_status(:ok)

      get "/cli/v1/vulnerabilities/runtimes", headers: headers
      expect(response).to have_http_status(:ok)
    end

    it "NON può far ripartire la scansione → 403 R403-CLIAUTH-002" do
      expect do
        post "/cli/v1/vulnerabilities/rescan", params: { project_id: project.id }, headers: headers
      end.not_to have_enqueued_job(Vulnerabilities::ScanProjectJob)

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
    end

    it "non vede i finding dei progetti che non gli sono assegnati" do
      invisibile = finding_for(create(:project, organization:))
      get "/cli/v1/vulnerabilities", headers: headers

      expect(response.parsed_body["data"].map { |f| f["id"] }).not_to include(invisibile.id)
    end
  end

  # La lista si guarda ogni giorno su decine di progetti: un N+1 qui si sente. Prosopite gira su ogni
  # request spec e solleva da solo — questo esempio serve solo a dargli abbastanza righe da inciampare.
  it "index preloada advisory, progetto e manifest" do
    create(:membership, account:, organization:, role: :owner)
    3.times { finding_for(project) }
    3.times { finding_for(create(:project, organization:)) }

    get "/cli/v1/vulnerabilities", headers: { "Authorization" => "Bearer #{token_for(account)}" }

    expect(response.parsed_body["data"].size).to eq(6)
  end
end
