# frozen_string_literal: true

require "rails_helper"

# Una riga della pagina "Cosa non torna" (CYRA-409): il punteggio di rischio con cui si ordina
# «prima ciò che conta di più». Produzione domina, poi un nome che sa di chiave, poi la categoria.
RSpec.describe Secrets::Health::AnomalyRow do
  def build_row(code: "staging", name: "DEBUG", kind: :drift_hole)
    environment = Types::Environment.new(code: code)
    project = Projects::Project.new(name: "Progetto")
    anomaly = Secrets::HealthCheck::Anomaly.new(kind: kind, project: project, environment: environment, secret_name: name)
    record = Secrets::HealthAnomaly.new(first_seen_at: Time.current, status: :open)
    described_class.new(anomaly: anomaly, record: record)
  end

  describe "#production?" do
    it "vero solo per l'ambiente production" do
      expect(build_row(code: "production")).to be_production
      expect(build_row(code: "staging")).not_to be_production
    end
  end

  describe "#sensitive_name?" do
    it "vero per nomi che indicano una chiave/segreto" do
      expect(build_row(name: "API_KEY")).to be_sensitive_name
      expect(build_row(name: "DATABASE_PASSWORD")).to be_sensitive_name
      expect(build_row(name: "LOG_LEVEL")).not_to be_sensitive_name
    end
  end

  describe "#risk_score" do
    it "la produzione pesa più di qualsiasi altra cosa" do
      prod_plain = build_row(code: "production", name: "LOG_LEVEL")
      staging_sensitive = build_row(code: "staging", name: "API_KEY")

      expect(prod_plain.risk_score).to be > staging_sensitive.risk_score
    end

    it "a parità di ambiente, un nome sensibile pesa di più" do
      sensitive = build_row(code: "staging", name: "SECRET_TOKEN")
      plain = build_row(code: "staging", name: "TIMEOUT")

      expect(sensitive.risk_score).to be > plain.risk_score
    end

    it "a parità di ambiente e nome, una delega rotta pesa più di un ambiente vuoto" do
      broken = build_row(code: "staging", name: "X", kind: :broken_delegation)
      empty = build_row(code: "staging", name: "X", kind: :empty_environment)

      expect(broken.risk_score).to be > empty.risk_score
    end
  end
end
