# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Projects::Secrets", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:environment) { create(:environment, organization:, code: "production").tap { |e| project.environments << e } }

  def token_for(acc)
    Accounts::ApiTokens::Issue.call(account: acc, organization:, name: "CLI").value[:secret]
  end

  def seed_secret(name:, value: "v")
    Secrets::Variables::Set.call(project:, environment:, name:, value:).value
  end

  # Protegge la coppia [project, environment] con l'approvazione a due (master opt-in del progetto +
  # capability approval risolta ON sulla riga join): stesso schema di Secrets::Approval, come protect!
  # in submit_spec. `environment` è già dichiarato dal progetto (il let fa `<<`, crea la riga join):
  # qui la si AGGIORNA, non se ne crea una seconda.
  def enable_approval!
    project.update!(secret_approval_enabled: true)
    project.project_environments.find_by!(environment:).update!(approval_required: true)
  end

  context "owner (ramo privilegiato: vede e gestisce tutto)" do
    before { create(:membership, account:, organization:, role: :owner) }
    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    it "index → 200 con i metadati, MAI il valore" do
      seed_secret(name: "DATABASE_URL", value: "postgres://x")
      get "/cli/v1/projects/#{project.id}/secrets", params: { environment: "production" }, headers: headers

      expect(response).to have_http_status(:ok)
      row = response.parsed_body["data"].first
      expect(row["name"]).to eq("DATABASE_URL")
      expect(row).not_to have_key("value")
    end

    it "create → 201 e cifra il valore (upsert)" do
      environment # dichiara l'ambiente
      post "/cli/v1/projects/#{project.id}/secrets", headers: headers,
                                                     params: { confirm: "1", environment: "production", name: "API_KEY", value: "s3cr3t" }

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["data"]["name"]).to eq("API_KEY")
      expect(project.secret_variables.find_by(name: "API_KEY").value).to eq("s3cr3t")
    end

    # CYRA-777 — l'avviso «questo valore ce l'hanno anche altri»: un conteggio e un indirizzo, mai i
    # nomi dei progetti. Chi può scrivere un segreto di un progetto non ha per forza il permesso di
    # sapere quali altri progetti esistono.
    describe "avviso «valore in comune»" do
      let(:altro) do
        create(:project, organization:, name: "progetto-gemello").tap { |p| p.environments << environment }
      end

      it "compare quando un altro progetto tiene già lo stesso valore" do
        Secrets::Variables::Set.call(project: altro, environment:, name: "CHIAVE_API", value: "valore-condiviso-lungo")

        post "/cli/v1/projects/#{project.id}/secrets", headers: headers,
             params: { confirm: "1", environment: "production", name: "API_KEY", value: "valore-condiviso-lungo" }

        avviso = response.parsed_body.dig("meta", "consolidation")
        expect(avviso["count"]).to eq(2)
        expect(avviso["url"]).to be_present
        expect(response.body).not_to include("progetto-gemello")
      end

      it "non compare quando il valore è solo di questo progetto" do
        environment

        post "/cli/v1/projects/#{project.id}/secrets", headers: headers,
             params: { confirm: "1", environment: "production", name: "API_KEY", value: "valore-solo-mio-lungo" }

        expect(response.parsed_body["meta"]).to be_nil
      end

      it "manda alla proposta quando esiste già" do
        Secrets::Variables::Set.call(project: altro, environment:, name: "CHIAVE_API", value: "valore-condiviso-lungo")
        Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "valore-condiviso-lungo")
        Secrets::Consolidation::Refresh.call(organization:)
        suggestion = Secrets::Consolidation::Suggestion.last

        post "/cli/v1/projects/#{project.id}/secrets", headers: headers,
             params: { confirm: "1", environment: "production", name: "API_KEY", value: "valore-condiviso-lungo" }

        expect(response.parsed_body.dig("meta", "consolidation", "url"))
          .to eq("/member/vault/consolidations/#{suggestion.id}")
      end
    end

    it "create due volte con lo stesso nome → upsert, non duplica" do
      environment
      post "/cli/v1/projects/#{project.id}/secrets", headers: headers, params: { confirm: "1", environment: "production", name: "API_KEY", value: "old" }
      expect do
        post "/cli/v1/projects/#{project.id}/secrets", headers: headers, params: { confirm: "1", environment: "production", name: "API_KEY", value: "new" }
      end.not_to change { project.secret_variables.count }
      expect(project.secret_variables.find_by(name: "API_KEY").value).to eq("new")
    end

    it "bundle → 200 con la mappa decifrata name => value + audit read" do
      seed_secret(name: "A", value: "1")
      seed_secret(name: "B", value: "2")
      get "/cli/v1/projects/#{project.id}/secrets/bundle", params: { environment: "production" }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]).to eq({ "A" => "1", "B" => "2" })
      read = project.secret_events.find_by(action: "read")
      expect(read).to be_present
      expect(read.actor).to eq(account)
      expect(read.metadata["count"]).to eq(2)
    end

    it "create con nome invalido → 422 R422-SECRET-001" do
      environment
      post "/cli/v1/projects/#{project.id}/secrets", headers: headers, params: { confirm: "1", environment: "production", name: "BAD-NAME", value: "v" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-SECRET-001")
    end

    it "create con stringa vuota esplicita → 201" do
      environment
      post "/cli/v1/projects/#{project.id}/secrets", headers: headers,
                                                     params: { confirm: "1", environment: "production", name: "OPTIONAL_VALUE", value: "" }

      expect(response).to have_http_status(:created)
      expect(project.secret_variables.find_by!(name: "OPTIONAL_VALUE").value).to eq("")
    end

    it "create senza value → 422 R422-SECRET-001" do
      environment
      post "/cli/v1/projects/#{project.id}/secrets", headers: headers,
                                                     params: { confirm: "1", environment: "production", name: "BROKEN_VALUE" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("R422-SECRET-001")
    end

    it "create con prefisso riservato GITHUB_ → 422 R422-SECRET-001" do
      environment
      post "/cli/v1/projects/#{project.id}/secrets", headers: headers, params: { confirm: "1", environment: "production", name: "GITHUB_TOKEN", value: "v" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-SECRET-001")
    end

    it "bundle senza environment → 422 R422-SECRET-001" do
      get "/cli/v1/projects/#{project.id}/secrets/bundle", headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-SECRET-001")
    end

    it "destroy per nome (con environment) → 204" do
      seed_secret(name: "API_KEY")
      delete "/cli/v1/projects/#{project.id}/secrets/API_KEY", params: { confirm: "1", environment: "production" }, headers: headers

      expect(response).to have_http_status(:no_content)
      expect(project.secret_variables.find_by(name: "API_KEY")).to be_nil
    end

    it "destroy per UUID → 204" do
      variable = seed_secret(name: "API_KEY")
      delete "/cli/v1/projects/#{project.id}/secrets/#{variable.id}", params: { confirm: "1" }, headers: headers

      expect(response).to have_http_status(:no_content)
      expect(Secrets::Variable.exists?(variable.id)).to be(false)
    end

    it "destroy per NOME senza environment → 422 (input invalido, non 404 secret inesistente)" do
      seed_secret(name: "API_KEY")
      delete "/cli/v1/projects/#{project.id}/secrets/API_KEY", params: { confirm: "1" }, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-SECRET-001")
      expect(project.secret_variables.find_by(name: "API_KEY")).to be_present
    end

    it "import bulk → 201 con il conteggio importato" do
      environment
      # upsert per-voce intenzionale su una lista bounded (import .env), non un N+1 lazy-load di produzione.
      allow_n_plus_one do
        post "/cli/v1/projects/#{project.id}/secrets/import", headers: headers,
                                                              params: { confirm: "1", environment: "production", variables: [ { name: "A", value: "1" }, { name: "B", value: "2" } ] }
      end

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["data"]["imported"]).to eq(2)
      expect(project.secret_variables.count).to eq(2)
    end

    it "import bulk con una voce invalida → 422 e nessuna scrittura (all-or-nothing)" do
      environment
      allow_n_plus_one do
        post "/cli/v1/projects/#{project.id}/secrets/import", headers: headers,
                                                              params: { confirm: "1", environment: "production", variables: [ { name: "GOOD", value: "1" }, { name: "BAD-NAME", value: "2" } ] }
      end

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-SECRET-001")
      expect(project.secret_variables.count).to eq(0)
    end

    it "sync → 202 e enfila il SyncJob quando il progetto ha un repo GitHub" do
      repo = create(:github_repository, :with_env_mapping, project:,
                    installation: create(:github_installation, organization:), sync_secrets: true)
      # Il preflight vero leggerebbe la configurazione su GitHub: qui si prova l'accodamento.
      allow(Secrets::Github::Preflight).to receive(:call).with(repository: repo).and_return(Result.ok([]))

      expect { post "/cli/v1/projects/#{project.id}/secrets/sync", headers: headers }
        .to have_enqueued_job(Secrets::Github::SyncJob).with(github_repository_id: repo.id)
      expect(response).to have_http_status(:accepted)
      expect(response.parsed_body["data"]["enqueued"]).to be(true)
    end

    # CYRA-637 — il gemello web registra l'esito da CYRA-106. Senza, un tentativo fermato dal
    # terminale lasciava la scheda del progetto sul «riuscito» di ieri.
    it "sync bloccato dal terminale lascia scritto il fallimento sul repository" do
      repo = create(:github_repository, :with_env_mapping, project:,
                    installation: create(:github_installation, organization:), sync_secrets: true)
      repo.update_columns(last_sync_status: "ok", last_sync_at: 2.days.ago, last_sync_error: {})
      errore = AppError.new("ambienti non collegati", code: "R422-GITHUB-011", details: { unmapped: %w[production] })
      allow(Secrets::Github::Preflight).to receive(:call).with(repository: repo).and_return(Result.err(errore))

      post "/cli/v1/projects/#{project.id}/secrets/sync", headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      repo.reload
      expect(repo).not_to be_last_sync_ok
      expect(repo.last_sync_error["code"]).to eq("R422-GITHUB-011")
    end

    it "sync con un valore null legacy → 422 con i soli nomi e nessun job" do
      repo = create(:github_repository, :with_env_mapping, project:,
                    installation: create(:github_installation, organization:), sync_secrets: true)
      error = AppError.new("variabili senza valore", code: "R422-GITHUB-009",
                                                    details: { unset: %w[BROKEN_VALUE] })
      allow(Secrets::Github::Preflight).to receive(:call).with(repository: repo).and_return(Result.err(error))

      expect { post "/cli/v1/projects/#{project.id}/secrets/sync", headers: headers }
        .not_to have_enqueued_job(Secrets::Github::SyncJob)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("R422-GITHUB-009")
      expect(response.parsed_body.dig("error", "details", "unset")).to eq(%w[BROKEN_VALUE])
    end

    it "sync con una sorgente bundle mancante → 422 immediato e nessun job" do
      repo = create(:github_repository, :with_env_mapping, project:,
                    installation: create(:github_installation, organization:), sync_secrets: true)
      error = AppError.new("sorgenti mancanti", code: "R422-GITHUB-007",
                                                 details: { missing: %w[CACHE_DATABASE_URL] })
      allow(Secrets::Github::Preflight).to receive(:call).with(repository: repo).and_return(Result.err(error))

      expect { post "/cli/v1/projects/#{project.id}/secrets/sync", headers: headers }
        .not_to have_enqueued_job(Secrets::Github::SyncJob)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("R422-GITHUB-007")
      expect(response.parsed_body.dig("error", "details", "missing")).to eq(%w[CACHE_DATABASE_URL])
    end

    it "sync senza repo GitHub → 404 R404-GITHUB-002" do
      post "/cli/v1/projects/#{project.id}/secrets/sync", headers: headers
      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body["error"]["code"]).to eq("R404-GITHUB-002")
    end

    it "progetto di un'altra org → 404 (anti-BOLA)" do
      other = create(:project)
      get "/cli/v1/projects/#{other.id}/secrets", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    # CYRA-230: con l'approvazione a due attiva, il canale CLI NON deve più applicare subito — deve
    # accodare una richiesta in attesa, esattamente come la pagina web (Secrets::ChangeRequests::Submit).
    context "ambiente protetto dall'approvazione a due (CYRA-230)" do
      before { enable_approval! }

      it "create → 202, nasce una richiesta in attesa e NIENTE viene scritto" do
        post "/cli/v1/projects/#{project.id}/secrets", headers: headers,
                                                       params: { confirm: "1", environment: "production", name: "API_KEY", value: "s3cr3t" }

        expect(response).to have_http_status(:accepted)
        expect(response.parsed_body["data"]["name"]).to eq("API_KEY")
        expect(response.parsed_body["data"]["status"]).to eq("pending")
        expect(response.parsed_body["data"]).not_to have_key("value")
        expect(project.secret_variables.find_by(name: "API_KEY")).to be_nil
        expect(Secrets::ChangeRequest.pending.where(name: "API_KEY", action: :set)).to exist
      end

      it "import → 202, nasce una richiesta in attesa per ogni variabile e NIENTE viene scritto" do
        allow_n_plus_one do
          post "/cli/v1/projects/#{project.id}/secrets/import", headers: headers,
                                                                params: { confirm: "1", environment: "production", variables: [ { name: "A", value: "1" }, { name: "B", value: "2" } ] }
        end

        expect(response).to have_http_status(:accepted)
        expect(response.parsed_body["data"]["pending"]).to eq(2)
        expect(project.secret_variables.count).to eq(0)
        expect(Secrets::ChangeRequest.pending.count).to eq(2)
      end

      it "import con una voce invalida → 422 e nessuna richiesta creata (all-or-nothing)" do
        allow_n_plus_one do
          post "/cli/v1/projects/#{project.id}/secrets/import", headers: headers,
                                                                params: { environment: "production", variables: [ { name: "GOOD", value: "1" }, { name: "BAD-NAME", value: "2" } ] }
        end

        expect(response).to have_http_status(:unprocessable_content)
        expect(Secrets::ChangeRequest.count).to eq(0)
        expect(project.secret_variables.count).to eq(0)
      end

      it "destroy → 202, nasce una richiesta in attesa e la variabile resta al suo posto" do
        variable = seed_secret(name: "API_KEY")

        delete "/cli/v1/projects/#{project.id}/secrets/#{variable.id}", params: { confirm: "1" }, headers: headers

        expect(response).to have_http_status(:accepted)
        expect(response.parsed_body["data"]["action"]).to eq("remove")
        expect(Secrets::Variable.exists?(variable.id)).to be(true)
        expect(Secrets::ChangeRequest.pending.where(name: "API_KEY", action: :remove)).to exist
      end

      it "la richiesta creata da CLI compare nello stesso elenco della pagina web (Pending)" do
        post "/cli/v1/projects/#{project.id}/secrets", headers: headers,
                                                       params: { confirm: "1", environment: "production", name: "API_KEY", value: "s3cr3t" }

        pending = Secrets::ChangeRequests::Pending.new(account:, projects: organization.projects)
        expect(pending.requests.map(&:name)).to include("API_KEY")
      end
    end
  end

  context "membro che vede il progetto ma senza permessi secret" do
    before do
      create(:membership, account:, organization:, role: :member)
      create(:project_membership, account:, project:)
    end
    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    it "index → 403" do
      environment
      get "/cli/v1/projects/#{project.id}/secrets", params: { environment: "production" }, headers: headers
      expect(response).to have_http_status(:forbidden)
    end

    it "bundle → 403 (i valori sono gated secrets.read)" do
      environment
      get "/cli/v1/projects/#{project.id}/secrets/bundle", params: { environment: "production" }, headers: headers
      expect(response).to have_http_status(:forbidden)
    end

    it "sync → 403 (manca github.manage)" do
      post "/cli/v1/projects/#{project.id}/secrets/sync", headers: headers
      expect(response).to have_http_status(:forbidden)
    end
  end

  # CYRA-234 — github.manage copre l'aggancio del repo, NON la lettura dei VALORI del vault. Lanciare
  # il push dei secret verso GitHub esfiltra tutto il vault (inclusi gli shared delegati): richiede
  # anche secrets.read. Con solo github.manage l'operazione è rifiutata.
  context "attore con github.manage ma senza secrets.read (CYRA-234)" do
    let(:granter) { create(:account) }

    before do
      create(:membership, account:, organization:, role: :member)
      create(:project_membership, account:, project:)
      create(:membership, account: granter, organization:, role: :owner)
      Authorization::SetAccountPermissions.call(organization:, account:,
                                                allow_keys: [ "github.manage" ], actor: granter)
    end
    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    it "sync → 403 e nessun push accodato (github.manage non basta a leggere i valori)" do
      create(:github_repository, project:, installation: create(:github_installation, organization:))

      expect { post "/cli/v1/projects/#{project.id}/secrets/sync", headers: headers }
        .not_to have_enqueued_job(Secrets::Github::SyncJob)
      expect(response).to have_http_status(:forbidden)
    end
  end

  context "attore con github.manage e secrets.read (CYRA-234)" do
    let(:granter) { create(:account) }

    before do
      create(:membership, account:, organization:, role: :member)
      create(:project_membership, account:, project:)
      create(:membership, account: granter, organization:, role: :owner)
      Authorization::SetAccountPermissions.call(organization:, account:,
                                                allow_keys: [ "github.manage", "secrets.read" ], actor: granter)
    end
    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    it "sync → 202 e enfila il SyncJob (entrambi i permessi presenti)" do
      repo = create(:github_repository, :with_env_mapping, project:,
                    installation: create(:github_installation, organization:), sync_secrets: true)
      allow(Secrets::Github::Preflight).to receive(:call).with(repository: repo).and_return(Result.ok([]))

      expect { post "/cli/v1/projects/#{project.id}/secrets/sync", headers: headers }
        .to have_enqueued_job(Secrets::Github::SyncJob).with(github_repository_id: repo.id)
      expect(response).to have_http_status(:accepted)
    end
  end

  context "membro con secrets.read ma senza secrets.manage" do
    let(:owner_account) { create(:account) }

    before do
      create(:membership, account:, organization:, role: :member)
      create(:project_membership, account:, project:)
      create(:membership, account: owner_account, organization:, role: :owner)
      Authorization::SetAccountPermissions.call(organization:, account:,
                                                allow_keys: [ "secrets.read" ], actor: owner_account)
    end
    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    it "bundle → 200 (può leggere i valori)" do
      seed_secret(name: "A", value: "1")
      get "/cli/v1/projects/#{project.id}/secrets/bundle", params: { environment: "production" }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]).to eq({ "A" => "1" })
    end

    it "create → 403 (set richiede secrets.manage)" do
      environment
      post "/cli/v1/projects/#{project.id}/secrets", headers: headers, params: { environment: "production", name: "X", value: "v" }
      expect(response).to have_http_status(:forbidden)
    end
  end

  # CYRA-721 — anche dal terminale leggere i valori e gestirli sono due permessi distinti. `secrets.manage`
  # non apre più il valore in chiaro: la lista dei NOMI resta (serve a chi gestisce per sapere cosa c'è),
  # ma bundle, get e il push verso GitHub — le tre strade per cui un valore esce dal vault — vogliono
  # `secrets.read`.
  context "membro con secrets.manage ma senza secrets.read (CYRA-721)" do
    let(:owner_account) { create(:account) }

    before do
      create(:membership, account:, organization:, role: :member)
      create(:project_membership, account:, project:)
      create(:membership, account: owner_account, organization:, role: :owner)
      Authorization::SetAccountPermissions.call(organization:, account:,
                                                allow_keys: [ "secrets.manage", "github.manage" ], actor: owner_account)
    end
    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    it "index → 200: i nomi si vedono (nessun valore è mai in lista)" do
      seed_secret(name: "DATABASE_URL", value: "postgres://x")

      get "/cli/v1/projects/#{project.id}/secrets", params: { environment: "production" }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"].first["name"]).to eq("DATABASE_URL")
    end

    it "create → 201: gestire si può ancora" do
      environment

      post "/cli/v1/projects/#{project.id}/secrets", headers: headers,
           params: { confirm: "1", environment: "production", name: "X", value: "v" }

      expect(response).to have_http_status(:created)
    end

    it "bundle → 403 e nessun valore nel corpo" do
      seed_secret(name: "A", value: "s3cr3t")

      get "/cli/v1/projects/#{project.id}/secrets/bundle", params: { environment: "production" }, headers: headers

      expect(response).to have_http_status(:forbidden)
      expect(response.body).not_to include("s3cr3t")
    end

    it "value → 403 e nessuna lettura registrata" do
      seed_secret(name: "A", value: "s3cr3t")

      expect do
        get "/cli/v1/projects/#{project.id}/secrets/A/value",
            params: { environment: "production" }, headers: headers
      end.not_to change { project.secret_events.where(action: "read").count }

      expect(response).to have_http_status(:forbidden)
      expect(response.body).not_to include("s3cr3t")
    end

    it "sync → 403 e nessun push accodato (gestire non autorizza a esfiltrare i valori)" do
      create(:github_repository, project:, installation: create(:github_installation, organization:))

      expect { post "/cli/v1/projects/#{project.id}/secrets/sync", headers: headers }
        .not_to have_enqueued_job(Secrets::Github::SyncJob)
      expect(response).to have_http_status(:forbidden)
    end
  end
end
