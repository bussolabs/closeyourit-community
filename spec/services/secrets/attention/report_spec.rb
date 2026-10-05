# frozen_string_literal: true

require "rails_helper"

# CYRA-428 — «Da sistemare» raccoglie in UNA lista sola ciò che prima viveva su tre pagine diverse
# (anomalie, rotazioni, richieste in attesa), ordinata per rischio. Qui si verifica l'unico contratto
# che quella pagina deve rispettare: quale livello di rischio prende ogni cosa, e in quale ordine
# esce la lista.
RSpec.describe Secrets::Attention::Report do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization: organization) }

  # Il reset dell'associazione serve perché i due ambienti nascono in momenti diversi: senza, il
  # progetto già in memoria non vedrebbe il secondo e la validazione «ambiente dichiarato» lo rifiuterebbe.
  def declare_environment(code)
    environment = create(:environment, organization: organization, code: code, label: code.titleize)
    create(:project_environment, project: project, environment: environment)
    project.environments.reset
    environment
  end

  let(:production) { declare_environment("production") }
  let(:staging) { declare_environment("staging") }

  # Una riga di anomalia come la costruisce Member::Vault::AttentionController: descrittore corrente
  # + record persistito (che porta first_seen_at).
  def anomaly_row(environment:, name: "DATABASE_URL", first_seen_at: 2.days.ago)
    descrittore = Secrets::HealthCheck::Anomaly.new(kind: :drift_hole, project: project,
                                                   environment: environment, secret_name: name)
    record = create(:secret_health_anomaly, project: project, organization: organization,
                                            environment: environment, secret_name: name,
                                            first_seen_at: first_seen_at)
    Secrets::Health::AnomalyRow.new(anomaly: descrittore, record: record)
  end

  # Una variabile con la rotazione già scaduta (o in scadenza, spostando l'intervallo).
  def rotating_variable(environment:, name:, days_ago:, interval:)
    create(:secret_variable, project: project, organization: organization, environment: environment,
                             name: name, rotation_interval_days: interval,
                             rotated_at: days_ago.days.ago)
  end

  def change_request(environment:, name: "API_TOKEN")
    create(:secret_change_request, project: project, organization: organization,
                                   environment: environment, name: name)
  end

  describe "livello di rischio" do
    it "un'anomalia in produzione è rischio alto, fuori produzione è medio" do
      report = described_class.new(anomaly_rows: [ anomaly_row(environment: production),
                                                   anomaly_row(environment: staging, name: "REDIS_URL") ])

      expect(report.items.map(&:risk)).to eq(%i[high medium])
    end

    it "una rotazione scaduta in produzione è rischio alto, fuori produzione è medio" do
      scaduta_prod = rotating_variable(environment: production, name: "PROD_KEY", days_ago: 90, interval: 30)
      scaduta_staging = rotating_variable(environment: staging, name: "STAGING_KEY", days_ago: 90, interval: 30)

      report = described_class.new(rotation_variables: [ scaduta_prod, scaduta_staging ])

      expect(report.items.map(&:risk)).to eq(%i[high medium])
    end

    it "una rotazione in scadenza è medio in produzione e basso fuori" do
      in_scadenza_prod = rotating_variable(environment: production, name: "PROD_SOON", days_ago: 29, interval: 30)
      in_scadenza_staging = rotating_variable(environment: staging, name: "STAGING_SOON", days_ago: 29, interval: 30)

      report = described_class.new(rotation_variables: [ in_scadenza_prod, in_scadenza_staging ])

      expect(report.items.map(&:risk)).to eq(%i[medium low])
    end

    it "una richiesta in attesa è media in produzione e bassa fuori" do
      report = described_class.new(change_requests: [ change_request(environment: production),
                                                      change_request(environment: staging, name: "OTHER_TOKEN") ])

      expect(report.items.map(&:risk)).to eq(%i[medium low])
    end
  end

  # CYRA-777 — la proposta di consolidamento è l'unica riga che non segnala un guasto: propone un
  # miglioramento. Da qui il rischio più basso e l'ultimo posto a parità di livello.
  describe "valore in comune" do
    def suggestion_on(environment)
      Secrets::Consolidation::Suggestion.create!(
        organization: organization, environment: environment,
        value_fingerprint: SecureRandom.hex(32), suggested_name: "API_KEY", projects_count: 2,
        first_seen_at: 3.days.ago, last_seen_at: Time.current
      )
    end

    it "è media in produzione e bassa fuori" do
      report = described_class.new(consolidations: [ suggestion_on(production), suggestion_on(staging) ])

      expect(report.items.map(&:risk)).to eq(%i[medium low])
    end

    it "non appartiene a nessun progetto: il progetto della riga è vuoto" do
      report = described_class.new(consolidations: [ suggestion_on(production) ])

      expect(report.items.first.project).to be_nil
      expect(report.items.first.secret_name).to eq("API_KEY")
    end

    it "sta dietro a una richiesta in attesa dello stesso livello" do
      report = described_class.new(change_requests: [ change_request(environment: production) ],
                                   consolidations: [ suggestion_on(production) ])

      expect(report.items.map(&:kind)).to eq(%i[change_request consolidation])
    end

    it "conta nel chip del proprio tipo" do
      report = described_class.new(consolidations: [ suggestion_on(production), suggestion_on(staging) ])

      expect(report.count_for(:consolidation)).to eq(2)
    end
  end

  describe "ordine della lista" do
    it "mette il rischio più alto in cima, qualunque sia la provenienza" do
      richiesta_prod = change_request(environment: production)
      anomalia_staging = anomaly_row(environment: staging, name: "REDIS_URL")
      scaduta_prod = rotating_variable(environment: production, name: "PROD_KEY", days_ago: 90, interval: 30)

      report = described_class.new(anomaly_rows: [ anomalia_staging ],
                                   rotation_variables: [ scaduta_prod ],
                                   change_requests: [ richiesta_prod ])

      expect(report.items.map(&:risk)).to eq(%i[high medium medium])
      expect(report.items.first.kind).to eq(:rotation_overdue)
    end

    # A parità di rischio conta cosa è più vicino alla rottura: una variabile che MANCA prima di una
    # che è solo da cambiare, e una richiesta che aspetta una decisione per ultima.
    it "a parità di rischio mette prima ciò che è più vicino alla rottura" do
      anomalia = anomaly_row(environment: staging, name: "REDIS_URL")
      scaduta = rotating_variable(environment: staging, name: "STAGING_KEY", days_ago: 90, interval: 30)
      richiesta = change_request(environment: staging)

      report = described_class.new(anomaly_rows: [ anomalia ], rotation_variables: [ scaduta ],
                                   change_requests: [ richiesta ])

      expect(report.items.map(&:kind)).to eq(%i[anomaly rotation_overdue change_request])
    end

    it "a parità di tipo e rischio mette prima quella aperta da più tempo" do
      recente = anomaly_row(environment: staging, name: "RECENTE", first_seen_at: 1.hour.ago)
      vecchia = anomaly_row(environment: staging, name: "VECCHIA", first_seen_at: 30.days.ago)

      report = described_class.new(anomaly_rows: [ recente, vecchia ])

      expect(report.items.map(&:secret_name)).to eq(%w[VECCHIA RECENTE])
    end
  end

  describe "conteggi" do
    it "conta il totale e quante cose sono a rischio alto" do
      report = described_class.new(
        anomaly_rows: [ anomaly_row(environment: production), anomaly_row(environment: staging, name: "REDIS_URL") ],
        change_requests: [ change_request(environment: staging) ]
      )

      expect(report.count).to eq(3)
      expect(report.high_count).to eq(1)
    end

    it "senza nulla da sistemare la lista è vuota" do
      report = described_class.new

      expect(report).not_to be_any
      expect(report.count).to be_zero
      expect(report.high_count).to be_zero
    end
  end

  # Una variabile senza regola di rotazione, o con la scadenza ancora lontana, non è una cosa da
  # sistemare adesso: entrerebbe nella lista a migliaia e la renderebbe illeggibile.
  it "ignora le variabili la cui rotazione non è né scaduta né vicina" do
    tranquilla = rotating_variable(environment: production, name: "CALMA", days_ago: 1, interval: 365)
    senza_regola = create(:secret_variable, project: project, organization: organization,
                                            environment: production, name: "SENZA_REGOLA")

    report = described_class.new(rotation_variables: [ tranquilla, senza_regola ])

    expect(report.items).to be_empty
  end
end
