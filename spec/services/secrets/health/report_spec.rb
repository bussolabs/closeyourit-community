# frozen_string_literal: true

require "rails_helper"

# Il modello di vista di "Cosa non torna" (CYRA-409): gruppi per progetto ordinati per rischio
# (produzione prima), assenze volute separate dai conteggi.
RSpec.describe Secrets::Health::Report do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org, name: "Progetto") }
  let(:production) { create(:environment, organization: org, code: "production").tap { |e| project.environments << e } }
  let(:staging) { create(:environment, organization: org, code: "staging").tap { |e| project.environments << e } }

  def anomaly(env:, name:, project: self.project, kind: :drift_hole)
    Secrets::HealthCheck::Anomaly.new(kind: kind, project: project, environment: env, secret_name: name)
  end

  def record_for(anomaly, *traits, **overrides)
    create(:secret_health_anomaly, *traits, project: anomaly.project, environment: anomaly.environment,
           kind: anomaly.kind, secret_name: anomaly.secret_name, **overrides)
  end

  it "un'anomalia attiva finisce in un gruppo di progetto, non tra le volute" do
    a = anomaly(env: staging, name: "VAR")
    report = described_class.new(anomalies: [ a ], records: { a.identity => record_for(a) })

    expect(report.active_count).to eq(1)
    expect(report.acknowledged_count).to eq(0)
    expect(report.project_groups.map(&:project)).to eq([ project ])
    expect(report.project_groups.first.rows.map(&:secret_name)).to eq([ "VAR" ])
  end

  it "ordina i progetti per rischio: quello con l'anomalia in produzione compare per primo" do
    other = create(:project, organization: org, name: "Altro")
    other_staging = create(:environment, organization: org, code: "staging").tap { |e| other.environments << e }

    prod_anomaly = anomaly(env: production, name: "PROD_VAR")
    staging_anomaly = anomaly(env: other_staging, name: "STAGING_VAR", project: other)
    records = { prod_anomaly.identity => record_for(prod_anomaly),
                staging_anomaly.identity => record_for(staging_anomaly) }

    report = described_class.new(anomalies: [ staging_anomaly, prod_anomaly ], records: records)

    expect(report.project_groups.map(&:project)).to eq([ project, other ])
  end

  it "dentro un progetto le righe sono ordinate per rischio (produzione in cima)" do
    prod = anomaly(env: production, name: "PLAIN")
    stag = anomaly(env: staging, name: "API_KEY")
    records = { prod.identity => record_for(prod), stag.identity => record_for(stag) }

    report = described_class.new(anomalies: [ stag, prod ], records: records)

    expect(report.project_groups.first.rows.map(&:environment)).to eq([ production, staging ])
  end

  it "un'anomalia acknowledged sta tra le volute e fuori dai conteggi attivi" do
    a = anomaly(env: staging, name: "VOLUTA")
    record = record_for(a, :acknowledged)
    report = described_class.new(anomalies: [ a ], records: { a.identity => record })

    expect(report.active_count).to eq(0)
    expect(report.project_groups).to be_empty
    expect(report.acknowledged.map(&:secret_name)).to eq([ "VOLUTA" ])
  end

  it "count_for conta solo le anomalie attive della categoria" do
    drift = anomaly(env: staging, name: "D", kind: :drift_hole)
    empty = anomaly(env: production, name: "", kind: :empty_environment)
    records = { drift.identity => record_for(drift), empty.identity => record_for(empty) }

    report = described_class.new(anomalies: [ drift, empty ], records: records)

    expect(report.count_for(:drift_hole)).to eq(1)
    expect(report.count_for(:empty_environment)).to eq(1)
    expect(report.count_for(:broken_delegation)).to eq(0)
  end
end
