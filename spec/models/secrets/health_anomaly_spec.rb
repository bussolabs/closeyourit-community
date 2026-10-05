# frozen_string_literal: true

require "rails_helper"

# Memoria persistita di un'anomalia del Vault (CYRA-409): tiene first_seen_at e la decisione
# «assenza voluta» (acknowledged). Il mantenimento degli stati vive in Secrets::Health::RecordAnomalies.
RSpec.describe Secrets::HealthAnomaly do
  describe "validazioni" do
    it "una anomalia costruita dal factory è valida" do
      expect(build(:secret_health_anomaly)).to be_valid
    end

    it "richiede first_seen_at e last_seen_at" do
      anomaly = build(:secret_health_anomaly, first_seen_at: nil, last_seen_at: nil)

      expect(anomaly).not_to be_valid
      expect(anomaly.errors[:first_seen_at]).to be_present
      expect(anomaly.errors[:last_seen_at]).to be_present
    end

    it "l'unique index DB vieta due anomalie con la stessa identità [progetto, ambiente, categoria, nome]" do
      first = create(:secret_health_anomaly, secret_name: "API_KEY")

      expect do
        create(:secret_health_anomaly, project: first.project, environment: first.environment,
               kind: first.kind, secret_name: "API_KEY")
      end.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "lo stesso nome in una categoria diversa è ammesso (identità diversa)" do
      first = create(:secret_health_anomaly, secret_name: "API_KEY", kind: :drift_hole)
      other = build(:secret_health_anomaly, project: first.project, environment: first.environment,
                    kind: :broken_delegation, secret_name: "API_KEY")

      expect(other).to be_valid
    end
  end

  describe "scope .active" do
    it "include open e acknowledged, esclude resolved" do
      open = create(:secret_health_anomaly)
      acknowledged = create(:secret_health_anomaly, :acknowledged, secret_name: "ACK_VAR")
      create(:secret_health_anomaly, :resolved, secret_name: "GONE_VAR")

      expect(described_class.active).to contain_exactly(open, acknowledged)
    end
  end

  describe "scope .for_projects" do
    it "tiene solo le anomalie dei progetti passati" do
      mine = create(:secret_health_anomaly)
      create(:secret_health_anomaly)

      expect(described_class.for_projects([ mine.project_id ])).to contain_exactly(mine)
    end
  end
end
