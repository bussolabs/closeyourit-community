# frozen_string_literal: true

require "rails_helper"

RSpec.describe Alerting::Rules::Save do
  let(:organization) { create(:organization) }
  let(:actor) { create(:account) }

  describe ".call" do
    it "crea la regola, imposta created_by sul nuovo record e ritorna Result.ok" do
      rule = organization.alerting_rules.new

      result = described_class.call(rule:, organization:, actor:,
                                    attributes: { name: "Nuovi errori", event_type: "error_new",
                                                  throttle_seconds: 300, enabled: true })

      expect(result).to be_ok
      expect(result.value).to be_persisted
      expect(result.value.created_by).to eq(actor)
      expect(result.value.name).to eq("Nuovi errori")
    end

    it "scoping anti-BOLA: project/environment di un'altra org → nil" do
      other_project = create(:project)         # altra org
      other_environment = create(:environment) # altra org
      rule = organization.alerting_rules.new

      result = described_class.call(rule:, organization:, actor:,
                                    attributes: { name: "X", event_type: "error_new", throttle_seconds: 60,
                                                  project_id: other_project.id,
                                                  environment_id: other_environment.id })

      expect(result).to be_ok
      expect(result.value.project_id).to be_nil
      expect(result.value.environment_id).to be_nil
    end

    it "project/environment della stessa org → assegnati" do
      project = create(:project, organization:)
      environment = create(:environment, organization:)
      rule = organization.alerting_rules.new

      result = described_class.call(rule:, organization:, actor:,
                                    attributes: { name: "Y", event_type: "uptime_down", throttle_seconds: 120,
                                                  project_id: project.id, environment_id: environment.id })

      expect(result.value.project_id).to eq(project.id)
      expect(result.value.environment_id).to eq(environment.id)
    end

    it "attributi invalidi (name blank) → Result.err R422-ALERT-001 con details" do
      rule = organization.alerting_rules.new

      result = described_class.call(rule:, organization:, actor:,
                                    attributes: { name: "", event_type: "error_new", throttle_seconds: 300 })

      expect(result).to be_err
      expect(result.error.code).to eq("R422-ALERT-001")
      expect(result.error.details).to have_key(:name)
    end
  end
end
