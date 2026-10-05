# frozen_string_literal: true

require "rails_helper"

# Osserva le anomalie correnti del Vault e ne mantiene la memoria persistita (CYRA-409): first_seen_at,
# riapertura, resolve delle sparite, e il rispetto della decisione «assenza voluta» (acknowledged).
RSpec.describe Secrets::Health::RecordAnomalies do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:environment) { create(:environment, organization: org, code: "production").tap { |e| project.environments << e } }

  # Costruisce un descrittore atomico come lo produrrebbe Secrets::HealthCheck#anomalies.
  def anomaly(name: "API_KEY", kind: :drift_hole, env: environment)
    Secrets::HealthCheck::Anomaly.new(kind: kind, project: project, environment: env, secret_name: name)
  end

  def call(anomalies, now: Time.current)
    described_class.call(organization: org, anomalies: anomalies, project_ids: [ project.id ], now: now)
  end

  it "apre un'anomalia mai vista con first_seen_at = ora" do
    now = Time.current

    result = call([ anomaly ], now: now)

    record = Secrets::HealthAnomaly.sole
    expect(record).to have_attributes(status: "open", secret_name: "API_KEY")
    expect(record.first_seen_at).to be_within(1.second).of(now)
    expect(result.value.values).to contain_exactly(record)
  end

  it "un'anomalia che persiste tiene il first_seen_at originale e aggiorna last_seen_at" do
    original = create(:secret_health_anomaly, project: project, environment: environment,
                      secret_name: "API_KEY", first_seen_at: 3.days.ago, last_seen_at: 3.days.ago)
    now = Time.current

    call([ anomaly ], now: now)

    original.reload
    expect(original.first_seen_at).to be_within(1.second).of(3.days.ago)
    expect(original.last_seen_at).to be_within(1.second).of(now)
    expect(original.status).to eq("open")
  end

  it "un'anomalia sparita (era open) diventa resolved" do
    create(:secret_health_anomaly, project: project, environment: environment, secret_name: "GONE")

    call([], now: Time.current)

    expect(Secrets::HealthAnomaly.sole.status).to eq("resolved")
  end

  it "un'anomalia resolved che ricompare torna open, mantenendo il first_seen_at" do
    create(:secret_health_anomaly, :resolved, project: project, environment: environment,
           secret_name: "API_KEY", first_seen_at: 10.days.ago)

    call([ anomaly ], now: Time.current)

    record = Secrets::HealthAnomaly.sole
    expect(record.status).to eq("open")
    expect(record.resolved_at).to be_nil
    expect(record.first_seen_at).to be_within(1.second).of(10.days.ago)
  end

  it "un'anomalia acknowledged NON torna open e NON viene risolta, presente o sparita" do
    acknowledged = create(:secret_health_anomaly, :acknowledged, project: project, environment: environment,
                          secret_name: "API_KEY")

    # Ancora presente: resta acknowledged.
    call([ anomaly ], now: Time.current)
    expect(acknowledged.reload.status).to eq("acknowledged")

    # Sparita: resta comunque acknowledged (la decisione permane).
    call([], now: Time.current)
    expect(acknowledged.reload.status).to eq("acknowledged")
  end

  it "ritorna solo le anomalie attive (open + acknowledged) indicizzate per identità" do
    call([ anomaly(name: "OPEN_VAR") ], now: Time.current)
    result = call([ anomaly(name: "OPEN_VAR") ], now: Time.current)

    record = Secrets::HealthAnomaly.find_by(secret_name: "OPEN_VAR")
    expect(result.value).to eq(record.then { |r| { [ r.project_id, r.environment_id, :drift_hole, "OPEN_VAR" ] => r } })
  end

  it "il resolve non tocca le anomalie di progetti non passati (scoping)" do
    other_project = create(:project, organization: org)
    other_env = create(:environment, organization: org).tap { |e| other_project.environments << e }
    foreign = create(:secret_health_anomaly, project: other_project, environment: other_env, secret_name: "FOREIGN")

    call([], now: Time.current)

    expect(foreign.reload.status).to eq("open")
  end

  it "non genera query per-record (nessun N+1) su molte anomalie" do
    envs = Array.new(3) { |i| create(:environment, organization: org, code: "env_#{i}").tap { |e| project.environments << e } }
    many = envs.flat_map { |env| [ anomaly(name: "A", env: env), anomaly(name: "B", env: env) ] }

    # Prosopite alza (raise) su un pattern di query ripetute: se ci fosse un N+1 questo fallirebbe.
    expect { call(many, now: Time.current) }.not_to raise_error
    expect(Secrets::HealthAnomaly.count).to eq(6)
  end
end
