require "rails_helper"

RSpec.describe Secrets::Github::Preflight do
  let(:repository) { create(:github_repository, :with_env_mapping, sync_secrets: true) }
  let(:project) { repository.project }
  let(:client) { instance_double(Github::Client) }

  before do
    allow(client).to receive(:repository_file).and_return(nil)
    # CYRA-652 — senza i file kamal il bundle non nasce, e il servizio chiede l'albero del ramo per
    # sapere se mancano davvero o se non riesce a leggerli. Qui mancano davvero.
    allow(client).to receive(:git_tree).and_return({ entries: [], truncated: false })
  end

  def seed(name, value, environment: repository.production_environment)
    Secrets::Variables::Set.call(project:, environment:, name:, value:, enqueue_sync: false).value
  end

  describe ".call" do
    it "accetta una stringa vuota impostata esplicitamente" do
      seed("OPTIONAL_VALUE", "")

      result = described_class.call(repository:, client:)

      expect(result).to be_ok
      production = result.value.find { |slot| slot.name == "production" }
      expect(production.bundle).to include("OPTIONAL_VALUE" => "")
      expect(production.secrets_json).to be_nil
    end

    it "rifiuta un valore null legacy prima di accodare il sync" do
      allow(Secrets::Bundle).to receive(:call).and_call_original
      allow(Secrets::Bundle).to receive(:call)
        .with(project:, environment: repository.production_environment, account: nil)
        .and_return(Result.ok("BROKEN_VALUE" => nil))

      result = described_class.call(repository:, client:)

      expect(result).to be_err
      expect(result.error.code).to eq("R422-GITHUB-009")
      expect(result.error.details).to eq(unset: %w[BROKEN_VALUE], slot: "production")
    end

    it "un null in staging blocca atomicamente anche production" do
      seed("PRODUCTION_VALUE", "ok")
      allow(Secrets::Bundle).to receive(:call).and_call_original
      allow(Secrets::Bundle).to receive(:call)
        .with(project:, environment: repository.staging_environment, account: nil)
        .and_return(Result.ok("BROKEN_STAGING" => nil))

      result = described_class.call(repository:, client:)

      expect(result).to be_err
      expect(result.error.details).to eq(unset: %w[BROKEN_STAGING], slot: "staging")
    end

    it "rifiuta un repository col sync disattivato" do
      repository.update_column(:sync_secrets, false)

      result = described_class.call(repository:, client:)

      expect(result).to be_err
      expect(result.error.code).to eq("R422-GITHUB-006")
    end

    it "rifiuta prima dell'accodamento una sorgente richiesta dal bundle ma assente nello slot" do
      allow(client).to receive(:repository_file)
        .with(anything, repository.full_name, ".kamal/secrets-common", ref: repository.default_branch)
        .and_return("CACHE_DATABASE_URL=$CACHE_DATABASE_URL\n")

      result = described_class.call(repository:, client:)

      expect(result).to be_err
      expect(result.error.code).to eq("R422-GITHUB-007")
      expect(result.error.details).to eq(missing: %w[CACHE_DATABASE_URL], slot: "production")
    end

    # CYRA-522 — con production e staging entrambi mappati, una sorgente che manca in UN SOLO slot
    # deve fermare tutto il sync: production è pronto ma non viene preparato, così il job non spinge
    # un bundle a metà su un environment e l'altro no.
    #
    # CYRA-106 — e l'errore dice QUALE slot lo ha bloccato: senza, chi legge l'esito nella scheda
    # vede un fallimento che non sa dove andare a correggere (production e staging hanno file diversi).
    it "una sorgente mancante nel solo staging blocca anche production, e lo dichiara" do
      seed("PRODUCTION_VALUE", "ok")
      allow(client).to receive(:repository_file)
        .with(anything, repository.full_name, ".kamal/secrets.staging", ref: repository.default_branch)
        .and_return("CACHE_DATABASE_URL=$CACHE_DATABASE_URL\n")

      result = described_class.call(repository:, client:)

      expect(result).to be_err
      expect(result.error.code).to eq("R422-GITHUB-007")
      expect(result.error.details).to eq(missing: %w[CACHE_DATABASE_URL], slot: "staging")
    end

    # CYRA-637 — un ambiente che il progetto ha e che il repository non mappa veniva saltato in
    # silenzio: il sync scriveva sugli altri slot e si dichiarava riuscito. Il guasto usciva mesi
    # dopo, al primo rilascio in produzione, con la cassetta di quell'ambiente vuota.
    it "si ferma se il progetto ha un ambiente che corrisponde a uno slot e il repository non lo mappa" do
      seed("PRODUCTION_VALUE", "ok")
      repository.update_columns(production_environment_id: nil)

      result = described_class.call(repository: repository.reload, client:)

      expect(result).to be_err
      expect(result.error.code).to eq("R422-GITHUB-011")
      expect(result.error.details).to eq(unmapped: %w[production])
    end

    it "non si ferma per un ambiente che il progetto non ha: chi ne usa uno solo resta intero" do
      seed("STAGING_VALUE", "ok", environment: repository.staging_environment)
      production = repository.production_environment
      repository.update_columns(production_environment_id: nil)
      project.environments.delete(production)

      result = described_class.call(repository: repository.reload, client:)

      expect(result).to be_ok
      expect(result.value.map(&:name)).to eq(%w[staging])
    end

    it "non si ferma per un ambiente dichiarato ma vuoto: lì non c'è nessuna sincronizzazione parziale" do
      seed("STAGING_VALUE", "ok", environment: repository.staging_environment)
      repository.update_columns(production_environment_id: nil)

      result = described_class.call(repository: repository.reload, client:)

      expect(result).to be_ok
      expect(result.value.map(&:name)).to eq(%w[staging])
    end

    # Revisione Codex — tre modi in cui la domanda «questo ambiente è stato dimenticato?» dava la
    # risposta sbagliata.
    it "non si ferma per un ambiente collegato a uno slot che porta un altro nome" do
      seed("PRODUCTION_VALUE", "ok")
      production = repository.production_environment
      # L'ambiente pieno è collegato, ma allo slot dell'altro nome: è già sincronizzato, non
      # dimenticato. Guardare i nomi invece degli id lo farebbe risultare saltato.
      repository.update_columns(production_environment_id: nil, staging_environment_id: production.id)

      result = described_class.call(repository: repository.reload, client:)

      expect(result).to be_ok
      expect(result.value.map(&:name)).to eq(%w[staging])
    end

    it "non conta i valori tracciati per uno slot occupato da un altro ambiente" do
      production = repository.production_environment
      seed("STAGING_VALUE", "ok", environment: repository.staging_environment)
      # Lo slot `production` porta l'ambiente di staging, e i nomi tracciati sotto quella chiave sono
      # i suoi. L'ambiente `production`, vuoto e scollegato, non è stato dimenticato da nessuno.
      repository.update_columns(production_environment_id: repository.staging_environment_id,
                                staging_environment_id: nil,
                                synced_secret_names: { "production" => %w[TRACCIATO] })
      expect(production.reload).to be_present

      result = described_class.call(repository: repository.reload, client:)

      expect(result).to be_ok
    end

    it "si ferma per uno slot libero che ha ancora valori scritti, anche senza un ambiente omonimo" do
      seed("STAGING_VALUE", "ok", environment: repository.staging_environment)
      # Lo slot production portava un ambiente dal codice tutto suo, e ci ha scritto. Ora è scollegato:
      # quei valori sono rimasti su GitHub e nessun ambiente omonimo esiste per farli notare.
      project.environments.delete(repository.production_environment)
      repository.update_columns(production_environment_id: nil,
                                synced_secret_names: { "production" => %w[ORFANO] })

      result = described_class.call(repository: repository.reload, client:)

      expect(result).to be_err
      expect(result.error.details).to eq(unmapped: %w[production])
    end

    it "si ferma per un ambiente pieno che nessuno slot collega, anche se lo slot omonimo è occupato" do
      seed("PRODUCTION_VALUE", "ok")
      staging = repository.staging_environment
      # Lo slot `staging` porta l'ambiente production; l'ambiente `staging`, pieno, non è collegato a
      # niente. Il suo contenuto non viene scritto da nessuna parte: è il guasto del ticket.
      Secrets::Variables::Set.call(project:, environment: staging, name: "STAGING_VALUE", value: "ok",
                                   enqueue_sync: false)
      repository.update_columns(production_environment_id: nil,
                                staging_environment_id: repository.production_environment_id)

      result = described_class.call(repository: repository.reload, client:)

      expect(result).to be_err
      expect(result.error.details).to eq(unmapped: %w[staging])
    end

    # Cinque progetti portano ancora `KAMAL_SECRETS_JSON` come variabile vera: righe più vecchie
    # della validazione che oggi le rifiuta. Il sync le toglie comunque dal bundle, quindi un
    # ambiente che ha soltanto quelle non ha niente da scrivere.
    it "non si ferma per un ambiente che porta soltanto una copia legacy dei nomi derivati" do
      seed("STAGING_VALUE", "ok", environment: repository.staging_environment)
      legacy = seed("VECCHIO_BUNDLE", "{}")
      legacy.update_column(:name, "KAMAL_SECRETS_JSON")
      repository.update_columns(production_environment_id: nil)

      result = described_class.call(repository: repository.reload, client:)

      expect(result).to be_ok
      expect(result.value.map(&:name)).to eq(%w[staging])
    end

    # I nomi derivati dal sync nel vault non entrano (`Secrets::Variable` li rifiuta), ma un valore
    # CONDIVISO può portarli: là il divieto è sul solo prefisso GITHUB_. Il preflight poi li toglie dal
    # bundle, quindi un ambiente che ha soltanto quelli non ha niente da scrivere.
    it "non si ferma per un ambiente che porta soltanto valori condivisi coi nomi derivati dal sync" do
      seed("STAGING_VALUE", "ok", environment: repository.staging_environment)
      production = repository.production_environment
      valore = Secrets::Shared::Save.call(organization: project.organization, environment: production,
                                          name: "SECRETS_JSON", value: "{}").value
      Secrets::Shared::Delegate.call(shared_value: valore, project:)
      repository.update_columns(production_environment_id: nil)

      result = described_class.call(repository: repository.reload, client:)

      expect(result).to be_ok
      expect(result.value.map(&:name)).to eq(%w[staging])
    end

    it "si ferma per un ambiente che vive di soli valori condivisi" do
      seed("STAGING_VALUE", "ok", environment: repository.staging_environment)
      production = repository.production_environment
      valore = Secrets::Shared::Save.call(organization: project.organization, environment: production,
                                          name: "api_key", value: "condiviso").value
      Secrets::Shared::Delegate.call(shared_value: valore, project:)
      repository.update_columns(production_environment_id: nil)

      result = described_class.call(repository: repository.reload, client:)

      expect(result).to be_err
      expect(result.error.details).to eq(unmapped: %w[production])
    end

    it "si ferma per un ambiente svuotato che ha ancora dei valori scritti su GitHub" do
      seed("STAGING_VALUE", "ok", environment: repository.staging_environment)
      repository.update_columns(production_environment_id: nil,
                                synced_secret_names: { "production" => %w[VECCHIO] })

      result = described_class.call(repository: repository.reload, client:)

      expect(result).to be_err
      expect(result.error.details).to eq(unmapped: %w[production])
    end

    it "si ferma se non c'è nessuno slot da scrivere: una sincronizzazione che non scrive niente non è riuscita" do
      seed("PRODUCTION_VALUE", "ok")
      seed("STAGING_VALUE", "ok", environment: repository.staging_environment)
      repository.update_columns(production_environment_id: nil, staging_environment_id: nil)

      result = described_class.call(repository: repository.reload, client:)

      expect(result).to be_err
      expect(result.error.code).to eq("R422-GITHUB-011")
      expect(result.error.details[:unmapped]).to match_array(%w[production staging])
    end

    it "propaga un errore di lettura GitHub come risultato senza sollevare nella request" do
      allow(client).to receive(:repository_file)
        .and_raise(Github::Client::Error.new("upstream non disponibile", code: "R502-GITHUB-001"))

      result = described_class.call(repository:, client:)

      expect(result).to be_err
      expect(result.error.code).to eq("R502-GITHUB-001")
    end
  end
end
