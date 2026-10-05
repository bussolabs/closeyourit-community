require "rails_helper"

RSpec.describe Secrets::Github::Sync do
  let(:repository) { create(:github_repository, :with_env_mapping, sync_secrets: true) }
  let(:project) { repository.project }
  let(:production) { repository.production_environment }
  let(:client) { instance_double(Github::Client) }
  let(:public_key) do
    { "key_id" => "kid", "key" => Base64.strict_encode64(RbNaCl::PrivateKey.generate.public_key.to_bytes) }
  end

  before do
    allow(client).to receive(:environment_public_key).and_return(public_key)
    allow(client).to receive(:put_environment_secret)
    allow(client).to receive(:delete_environment_secret)
    allow(client).to receive(:repository_file).and_return(nil)
    # CYRA-652 — senza i file kamal il bundle non nasce, e ora il servizio chiede l'albero del ramo
    # per sapere se mancano davvero o se non riesce a leggerli. Qui mancano davvero.
    allow(client).to receive(:git_tree).and_return({ entries: [], truncated: false })
  end

  def seed(name, value, environment: production)
    Secrets::Variables::Set.call(project:, environment:, name:, value:, enqueue_sync: false).value
  end

  describe ".call" do
    it "cifra e PUTa ogni secret dello slot sul GitHub Environment omonimo, e traccia i nomi" do
      seed("A", "1")
      seed("B", "2")

      result = described_class.call(repository:, client:)

      expect(result).to be_ok
      expect(result.value[:pushed]).to eq(2)
      expect(client).to have_received(:put_environment_secret).with(anything, repository.repo_id, "production", "A", encrypted_value: anything, key_id: "kid")
      expect(client).to have_received(:put_environment_secret).with(anything, repository.repo_id, "production", "B", encrypted_value: anything, key_id: "kid")
      expect(repository.reload.synced_secret_names["production"]).to match_array(%w[A B])
      expect(project.secret_events.find_by(action: "synced").metadata)
        .to eq({ "pushed" => 2, "deleted" => 0, "environments" => %w[production staging] })
    end

    it "cancella SOLO i nomi già gestiti e ora spariti (mai i secret manuali)" do
      repository.update_column(:synced_secret_names, { "production" => %w[OLD A] })
      seed("A", "1")

      result = described_class.call(repository:, client:)

      expect(result.value[:deleted]).to eq(1)
      expect(client).to have_received(:delete_environment_secret).with(anything, repository.repo_id, "production", "OLD")
      expect(client).not_to have_received(:delete_environment_secret).with(anything, anything, anything, "A")
      expect(repository.reload.synced_secret_names["production"]).to eq(%w[A])
    end

    it "genera e sincronizza SECRETS_JSON senza persisterlo nel vault" do
      seed("DATABASE_URL", "postgres://db")
      seed("DATABASE_URL", "postgres://staging", environment: repository.staging_environment)
      allow(client).to receive(:repository_file)
        .with(anything, repository.full_name, ".kamal/secrets-common", ref: repository.default_branch)
        .and_return("DATABASE_URL=$DATABASE_URL\n")
      allow(client).to receive(:repository_file)
        .with(anything, repository.full_name, ".kamal/secrets", ref: repository.default_branch)
        .and_return(nil)

      result = described_class.call(repository:, client:)

      expect(result).to be_ok
      expect(client).to have_received(:put_environment_secret)
        .with(anything, repository.repo_id, "production", "SECRETS_JSON", encrypted_value: anything, key_id: "kid")
      expect(repository.reload.synced_secret_names["production"]).to include("SECRETS_JSON")
      expect(project.secret_variables.find_by(name: "SECRETS_JSON")).to be_nil
    end

    it "supporta lo slot preview: genera SECRETS_JSON da .kamal/secrets.preview" do
      prev = create(:environment, organization: project.organization, code: "preview")
      project.environments << prev
      repository.update!(preview_environment: prev)
      seed("DATABASE_URL", "postgres://preview", environment: prev)
      allow(client).to receive(:repository_file)
        .with(anything, repository.full_name, ".kamal/secrets.preview", ref: repository.default_branch)
        .and_return("DATABASE_URL=$DATABASE_URL\n")

      result = described_class.call(repository:, client:)

      expect(result).to be_ok
      expect(client).to have_received(:put_environment_secret)
        .with(anything, repository.repo_id, "preview", "SECRETS_JSON", encrypted_value: anything, key_id: "kid")
      expect(repository.reload.synced_secret_names["preview"]).to include("SECRETS_JSON")
    end

    it "non sincronizza copie persistite dei nomi derivati e rimuove il legacy già gestito" do
      legacy = seed("LEGACY_BUNDLE", "legacy")
      stale = seed("STALE_BUNDLE", "stale")
      legacy.update_column(:name, "KAMAL_SECRETS_JSON")
      stale.update_column(:name, "SECRETS_JSON")
      repository.update_column(:synced_secret_names, { "production" => %w[KAMAL_SECRETS_JSON SECRETS_JSON] })

      result = described_class.call(repository:, client:)

      expect(result).to be_ok
      expect(client).to have_received(:delete_environment_secret)
        .with(anything, repository.repo_id, "production", "KAMAL_SECRETS_JSON")
      expect(client).to have_received(:delete_environment_secret)
        .with(anything, repository.repo_id, "production", "SECRETS_JSON")
      expect(client).not_to have_received(:put_environment_secret)
        .with(anything, anything, anything, "KAMAL_SECRETS_JSON", encrypted_value: anything, key_id: anything)
      expect(repository.reload.synced_secret_names["production"]).to eq([])
    end

    it "non pubblica nulla se la configurazione richiede una chiave assente" do
      allow(client).to receive(:repository_file)
        .with(anything, repository.full_name, ".kamal/secrets-common", ref: repository.default_branch)
        .and_return("A=$MISSING\n")
      allow(client).to receive(:repository_file)
        .with(anything, repository.full_name, ".kamal/secrets", ref: repository.default_branch)
        .and_return(nil)

      result = described_class.call(repository:, client:)

      expect(result).to be_err
      expect(result.error.code).to eq("R422-GITHUB-007")
      expect(client).not_to have_received(:put_environment_secret)
    end

    # Regressione CYRA-213: un null nel vault finiva come `null` dentro SECRETS_JSON e poi come stringa
    # "null" nel container. Il valore null resta bloccato, mentre "" è un valore intenzionale distinto.
    it "non pubblica nulla se una variabile legacy ha valore null" do
      allow(Secrets::Bundle).to receive(:call).and_call_original
      allow(Secrets::Bundle).to receive(:call)
        .with(project:, environment: repository.production_environment, account: nil)
        .and_return(Result.ok("UNSET" => nil))

      result = described_class.call(repository:, client:)

      expect(result).to be_err
      expect(result.error.code).to eq("R422-GITHUB-009")
      expect(result.error.details).to eq(unset: %w[UNSET], slot: "production")
      expect(client).not_to have_received(:put_environment_secret)
      expect(client).not_to have_received(:delete_environment_secret)
    end

    it "sincronizza una stringa vuota impostata esplicitamente" do
      seed("OPTIONAL_VALUE", "")

      result = described_class.call(repository:, client:)

      expect(result).to be_ok
      expect(client).to have_received(:put_environment_secret)
        .with(anything, repository.repo_id, "production", "OPTIONAL_VALUE", encrypted_value: anything, key_id: "kid")
    end

    # Rilievo review CYRA-213: la validazione dei valori vuoti avveniva slot per slot, quindi un blank
    # nello slot staging lasciava production — processato prima — già scritto. Ora tutti gli slot sono
    # validati PRIMA di qualsiasi PUT/DELETE: un vuoto in uno slot ferma l'intero sync senza scrivere.
    it "un valore null in uno slot ferma l'intero sync senza scrivere gli altri slot" do
      seed("A", "1") # production: valido
      allow(Secrets::Bundle).to receive(:call).and_call_original
      allow(Secrets::Bundle).to receive(:call)
        .with(project:, environment: repository.staging_environment, account: nil)
        .and_return(Result.ok("UNSET" => nil))

      result = described_class.call(repository:, client:)

      expect(result).to be_err
      expect(result.error.code).to eq("R422-GITHUB-009")
      expect(result.error.details).to eq(unset: %w[UNSET], slot: "staging")
      expect(client).not_to have_received(:put_environment_secret)
      expect(client).not_to have_received(:delete_environment_secret)
    end

    # CYRA-79 — GUARDIA: i valori assegnati a una persona non escono MAI verso GitHub. Il push finisce
    # nei secret di un repo, dove lo usa chiunque faccia girare la pipeline: se un valore su misura ci
    # entrasse, l'eccezione di una persona diventerebbe la regola per tutti, in silenzio.
    it "non spinge i valori su misura: né come sostituzione né come variabile in più" do
      destinatario = create(:account)
      create(:membership, account: destinatario, organization: project.organization, role: :owner)
      seed("DATABASE_URL", "standard")
      Secrets::Overrides::Set.call(project:, environment: production, account: destinatario,
                                   name: "DATABASE_URL", value: "solo-suo", actor: destinatario)
      Secrets::Overrides::Set.call(project:, environment: production, account: destinatario,
                                   name: "SOLO_PER_ME", value: "extra", actor: destinatario)

      result = described_class.call(repository:, client:)

      expect(result).to be_ok
      # Il nome in più non viene nemmeno pubblicato...
      expect(repository.reload.synced_secret_names["production"]).to eq(%w[DATABASE_URL])
      expect(client).not_to have_received(:put_environment_secret)
        .with(anything, anything, anything, "SOLO_PER_ME", encrypted_value: anything, key_id: anything)
      # ...e il valore spinto è quello standard (il payload verso GitHub è cifrato a scatola chiusa:
      # si legge dal bundle che il preflight prepara, che è esattamente ciò che viene cifrato).
      prepared = Secrets::Github::Preflight.call(repository:, client:).value.find { |slot| slot.name == "production" }
      expect(prepared.bundle).to eq({ "DATABASE_URL" => "standard" })
    end

    # CYRA-637 — prima questo era un no-op che tornava `ok` con {pushed: 0, deleted: 0}: chi la
    # lanciava leggeva «riuscita» su una sincronizzazione che non aveva toccato niente. Ora si ferma.
    it "si ferma se non c'è nessuno slot mappato, invece di firmare un nulla" do
      unmapped = create(:github_repository, sync_secrets: true)
      result = described_class.call(repository: unmapped, client:)

      expect(result).to be_err
      expect(result.error.code).to eq("R422-GITHUB-011")
      expect(client).not_to have_received(:environment_public_key)
    end

    it "ritorna R422-GITHUB-006 se sync_secrets è off (nessuna chiamata GitHub)" do
      repository.update_column(:sync_secrets, false)

      result = described_class.call(repository:, client:)

      expect(result).to be_err
      expect(result.error.code).to eq("R422-GITHUB-006")
      expect(client).not_to have_received(:put_environment_secret)
    end

    it "propaga l'errore di trasporto GitHub come R502-GITHUB-001" do
      seed("A", "1")
      allow(client).to receive(:put_environment_secret).and_raise(Github::Client::Error.new("boom", code: "R502-GITHUB-001"))

      result = described_class.call(repository:, client:)

      expect(result).to be_err
      expect(result.error.code).to eq("R502-GITHUB-001")
    end
  end

  # CYRA-106 — il job che chiama questo service è fire-and-forget: un Result.err non solleva, quindi
  # senza una traccia scritta un invio fallito è indistinguibile da uno riuscito. Nel caso reale il
  # silenzio è costato 9 giorni. L'esito dell'ULTIMO tentativo resta sul repository: com'è andato,
  # quando, e — se è andato male — codice, slot e dettagli strutturati.
  describe "esito dell'ultimo invio" do
    it "registra l'invio riuscito con l'ora, e senza errore" do
      seed("A", "1")

      described_class.call(repository:, client:)

      repository.reload
      expect(repository).to be_last_sync_ok
      expect(repository.last_sync_at).to be_within(5.seconds).of(Time.current)
      expect(repository.last_sync_error).to eq({})
    end

    it "registra il fallimento con codice, slot e la riga di configurazione che lo blocca" do
      allow(client).to receive(:repository_file)
        .with(anything, repository.full_name, ".kamal/secrets", ref: repository.default_branch)
        .and_return("A=$A\nexport B=1\n")

      described_class.call(repository:, client:)

      repository.reload
      expect(repository).to be_last_sync_failed
      expect(repository.last_sync_at).to be_within(5.seconds).of(Time.current)
      expect(repository.last_sync_error).to include(
        "code" => "R422-GITHUB-007", "slot" => "production",
        "details" => { "path" => ".kamal/secrets", "line" => 2 }
      )
    end

    it "registra il fallimento di trasporto GitHub con lo slot su cui si è rotto" do
      seed("A", "1")
      allow(client).to receive(:put_environment_secret)
        .and_raise(Github::Client::Error.new("boom", code: "R502-GITHUB-001"))

      described_class.call(repository:, client:)

      repository.reload
      expect(repository).to be_last_sync_failed
      expect(repository.last_sync_error).to include("code" => "R502-GITHUB-001", "slot" => "production")
    end

    it "un invio riuscito cancella l'errore del tentativo precedente" do
      repository.update_columns(last_sync_status: "error", last_sync_at: 2.days.ago,
                                last_sync_error: { "code" => "R422-GITHUB-007" })
      seed("A", "1")

      described_class.call(repository:, client:)

      repository.reload
      expect(repository).to be_last_sync_ok
      expect(repository.last_sync_error).to eq({})
    end

    # CYRA-637 — il cuore del ticket: una sincronizzazione che non ha potuto scrivere ovunque era
    # attesa non può presentarsi come riuscita. Prima scriveva sugli slot rimasti, chiamava
    # `record_sync_success!` e lasciava una riga verde nella storia.
    it "una sincronizzazione parziale non si dichiara riuscita e non scrive niente" do
      seed("A", "1")
      repository.update_columns(production_environment_id: nil)

      result = described_class.call(repository: repository.reload, client:)

      expect(result).to be_err
      expect(result.error.code).to eq("R422-GITHUB-011")
      expect(client).not_to have_received(:put_environment_secret)
      repository.reload
      expect(repository).not_to be_last_sync_ok
      expect(repository.last_sync_error["code"]).to eq("R422-GITHUB-011")
      expect(project.secret_events.find_by(action: "synced")).to be_nil
    end

    it "l'evento dice su quali ambienti ha scritto, non solo quanti valori" do
      seed("A", "1")

      result = described_class.call(repository:, client:)

      expect(result.value[:environments]).to eq(%w[production staging])
      expect(project.secret_events.find_by(action: "synced").metadata["environments"]).to eq(%w[production staging])
    end

    it "non registra nulla quando il push dei secret è semplicemente spento" do
      repository.update_column(:sync_secrets, false)

      described_class.call(repository:, client:)

      repository.reload
      expect(repository.last_sync_status).to be_nil
      expect(repository.last_sync_at).to be_nil
    end
  end
end
