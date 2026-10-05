require "rails_helper"

RSpec.describe Secrets::Github::SecretsJson do
  let(:repository) { create(:github_repository, default_branch: "main") }
  let(:client) { instance_double(Github::Client) }
  let(:installation_id) { repository.installation.installation_id }

  def build(slot:, bundle:)
    described_class.call(repository:, slot:, bundle:, client:, installation_id:)
  end

  it "costruisce il JSON dai passthrough common + destination, con override dell'ultimo file" do
    allow(client).to receive(:repository_file)
      .with(installation_id, repository.full_name, ".kamal/secrets-common", ref: "main")
      .and_return("DATABASE_URL=$DATABASE_URL\nAPP_TOKEN=$COMMON_TOKEN\n")
    allow(client).to receive(:repository_file)
      .with(installation_id, repository.full_name, ".kamal/secrets.staging", ref: "main")
      .and_return("APP_TOKEN=$STAGING_TOKEN\n")

    result = build(
      slot: "staging",
      bundle: { "DATABASE_URL" => "postgres://db", "COMMON_TOKEN" => "common", "STAGING_TOKEN" => "staging" }
    )

    expect(result).to be_ok
    expect(JSON.parse(result.value)).to eq(
      "APP_TOKEN" => "staging",
      "DATABASE_URL" => "postgres://db"
    )
  end

  # CYRA-652 — «nessun file» e «non sono riuscito a leggerli» arrivavano identici: un nil. Il primo è
  # normale (un repository che Kamal non lo usa), il secondo è un guasto che si vede solo mesi dopo,
  # al rilascio, perché il bundle non è mai stato scritto e nessuno l'ha detto. Li separa l'albero del
  # ramo: se là dentro quei file non ci sono, non ci sono davvero.
  it "ritorna nil quando il repository non ha davvero i file secrets per lo slot" do
    allow(client).to receive(:repository_file).and_return(nil)
    allow(client).to receive(:git_tree)
      .with(installation_id, repository.full_name, "main")
      .and_return({ entries: [ { "path" => "README.md" } ], truncated: false })

    result = build(slot: "production", bundle: { "A" => "1" })

    expect(result).to be_ok
    expect(result.value).to be_nil
  end

  it "fallisce chiuso se i file esistono nel ramo ma non si riescono a leggere" do
    allow(client).to receive(:repository_file).and_return(nil)
    allow(client).to receive(:git_tree)
      .with(installation_id, repository.full_name, "main")
      .and_return({ entries: [ { "path" => ".kamal/secrets-common" }, { "path" => ".kamal/secrets" } ], truncated: false })

    result = build(slot: "production", bundle: { "A" => "1" })

    expect(result).to be_err
    expect(result.error.code).to eq("R422-GITHUB-012")
    expect(result.error.details[:unreadable]).to eq([ ".kamal/secrets-common", ".kamal/secrets" ])
  end

  # Ramo assente o repository senza commit: `git_tree` risponde nil, ed è lo stato normale di un
  # progetto appena collegato. Là dentro quei file davvero non ci sono.
  it "non si ferma su un repository senza commit" do
    allow(client).to receive(:repository_file).and_return(nil)
    allow(client).to receive(:git_tree).and_return(nil)

    result = build(slot: "production", bundle: { "A" => "1" })

    expect(result).to be_ok
    expect(result.value).to be_nil
  end

  # Il caso che il ticket chiude un livello più giù: UN file solo non si legge, l'altro sì. Il bundle
  # nascerebbe a metà — coi passthrough di un file soltanto — e nessuno lo direbbe.
  it "fallisce chiuso se un solo file non si legge ma il ramo lo elenca" do
    allow(client).to receive(:repository_file)
      .with(installation_id, repository.full_name, ".kamal/secrets-common", ref: "main").and_return(nil)
    allow(client).to receive(:repository_file)
      .with(installation_id, repository.full_name, ".kamal/secrets", ref: "main").and_return("A=$A\n")
    allow(client).to receive(:git_tree)
      .and_return({ entries: [ { "path" => ".kamal/secrets-common" }, { "path" => ".kamal/secrets" } ], truncated: false })

    result = build(slot: "production", bundle: { "A" => "1" })

    expect(result).to be_err
    expect(result.error.details[:unreadable]).to eq([ ".kamal/secrets-common" ])
  end

  # Un albero troncato non dice niente sull'assenza: GitHub taglia la lista e il file potrebbe essere
  # oltre il taglio. Meglio fermarsi che dichiarare assente ciò che non si è visto.
  it "fallisce chiuso su un albero troncato" do
    allow(client).to receive(:repository_file).and_return(nil)
    allow(client).to receive(:git_tree)
      .with(installation_id, repository.full_name, "main")
      .and_return({ entries: [ { "path" => "README.md" } ], truncated: true })

    result = build(slot: "production", bundle: { "A" => "1" })

    expect(result).to be_err
    expect(result.error.code).to eq("R422-GITHUB-012")
  end

  it "usa .kamal/secrets per production" do
    allow(client).to receive(:git_tree).and_return({ entries: [ { "path" => ".kamal/secrets" } ], truncated: false })
    allow(client).to receive(:repository_file)
      .with(installation_id, repository.full_name, ".kamal/secrets-common", ref: "main")
      .and_return(nil)
    expect(client).to receive(:repository_file)
      .with(installation_id, repository.full_name, ".kamal/secrets", ref: "main")
      .and_return("A=$A\n")

    expect(JSON.parse(build(slot: "production", bundle: { "A" => "1" }).value)).to eq("A" => "1")
  end

  it "usa .kamal/secrets.preview per preview" do
    allow(client).to receive(:git_tree).and_return({ entries: [ { "path" => ".kamal/secrets.preview" } ], truncated: false })
    allow(client).to receive(:repository_file)
      .with(installation_id, repository.full_name, ".kamal/secrets-common", ref: "main")
      .and_return(nil)
    expect(client).to receive(:repository_file)
      .with(installation_id, repository.full_name, ".kamal/secrets.preview", ref: "main")
      .and_return("A=$A\n")

    expect(JSON.parse(build(slot: "preview", bundle: { "A" => "1" }).value)).to eq("A" => "1")
  end

  it "fallisce chiuso se una riga non è un passthrough semplice" do
    allow(client).to receive(:repository_file).and_return("A=$(op read vault/item)\n")

    result = build(slot: "production", bundle: {})

    expect(result).to be_err
    expect(result.error.code).to eq("R422-GITHUB-007")
    expect(result.error.details).to include(path: ".kamal/secrets-common", line: 1)
  end

  # Regressione: un commento in coda alla riga faceva fallire l'INTERO sync del vault con
  # R422-GITHUB-007, e in silenzio (il job è fire-and-forget). È successo davvero su
  # closeyourit-rails: la sola riga POSTGRES_PASSWORD commentata teneva fermi tutti i secret.
  it "accetta un commento in coda alla riga di passthrough" do
    allow(client).to receive(:repository_file)
      .and_return("DATABASE_URL=$DATABASE_URL   # il database primario\nAPP_TOKEN=$APP_TOKEN\n")

    result = build(slot: "production", bundle: { "DATABASE_URL" => "postgres://db", "APP_TOKEN" => "t" })

    expect(result).to be_ok
    expect(JSON.parse(result.value)).to eq("DATABASE_URL" => "postgres://db", "APP_TOKEN" => "t")
  end

  it "non scambia per commento un cancelletto attaccato al nome della sorgente" do
    allow(client).to receive(:repository_file).and_return("A=$SOURCE#NOPE\n")

    result = build(slot: "production", bundle: { "SOURCE" => "x" })

    expect(result).to be_err
    expect(result.error.code).to eq("R422-GITHUB-007")
  end

  it "fallisce chiuso ed elenca solo i nomi delle sorgenti mancanti" do
    allow(client).to receive(:repository_file)
      .and_return("A=$MISSING_A\nB=$MISSING_B\n")

    result = build(slot: "production", bundle: {})

    expect(result).to be_err
    expect(result.error.code).to eq("R422-GITHUB-007")
    expect(result.error.details).to eq(missing: %w[MISSING_A MISSING_B])
  end

  # Regressione CYRA-213: una sorgente presente nel bundle ma col valore nil superava il check
  # `missing` (la CHIAVE c'è) e finiva come `null` nel JSON generato; nel container `jq -r` su quel
  # null produce la stringa "null", che come SECRET_ASSETS_MASTER_KEY non decodifica a 32 byte e
  # rende illeggibili i file segreti già caricati. Ora fallisce chiuso, come per le sorgenti mancanti.
  it "fallisce chiuso ed elenca le sorgenti col valore assente (mai emettere null nel JSON)" do
    allow(client).to receive(:repository_file)
      .and_return("SECRET_ASSETS_MASTER_KEY=$SECRET_ASSETS_MASTER_KEY\n")

    result = build(slot: "production", bundle: { "SECRET_ASSETS_MASTER_KEY" => nil })

    expect(result).to be_err
    expect(result.error.code).to eq("R422-GITHUB-009")
    expect(result.error.details).to eq(unset: %w[SECRET_ASSETS_MASTER_KEY])
  end

  it "mantiene una stringa vuota impostata esplicitamente senza trasformarla in null" do
    allow(client).to receive(:repository_file).and_return("A=$A\nB=$B\n")

    result = build(slot: "production", bundle: { "A" => "", "B" => "ok" })

    expect(result).to be_ok
    expect(JSON.parse(result.value)).to eq("A" => "", "B" => "ok")
  end

  it "non scambia per vuoto un valore falsy-like come \"0\" o \"false\"" do
    allow(client).to receive(:repository_file).and_return("A=$A\nB=$B\n")

    result = build(slot: "production", bundle: { "A" => "0", "B" => "false" })

    expect(result).to be_ok
    expect(JSON.parse(result.value)).to eq("A" => "0", "B" => "false")
  end

  it "rifiuta i nomi dei bundle derivati come target o sorgente" do
    allow(client).to receive(:repository_file).and_return("SECRETS_JSON=$A\n")

    result = build(slot: "production", bundle: { "A" => "1" })

    expect(result).to be_err
    expect(result.error.code).to eq("R422-GITHUB-007")
  end

  it "rifiuta il payload oltre il limite dei GitHub secret" do
    allow(client).to receive(:repository_file).and_return("BIG=$BIG\n")

    result = build(slot: "production", bundle: { "BIG" => "x" * 48_000 })

    expect(result).to be_err
    expect(result.error.code).to eq("R422-GITHUB-008")
  end
end
