# frozen_string_literal: true

require "rails_helper"

RSpec.describe Uptime::Monitors::Save do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:environment) { create(:environment, organization:) }
  let(:actor) { create(:account) }

  before do
    project.environments << environment
    # L'uptime esiste solo su progetti uptime-capable (piattaforma web/server).
    project.project_platforms.create!(platform: create(:platform, :uptime_capable, organization:))
  end

  let(:valid_attributes) do
    { url: "https://example.com/up", http_method: "GET",
      interval_seconds: 60, expected_status: 200, timeout_seconds: 5 }
  end

  describe "create" do
    it "fissa project, environment e created_by, con name auto-derivato dal model" do
      result = described_class.call(monitor: Uptime::Monitor.new, attributes: valid_attributes,
                                    project:, environment_id: environment.id, actor:)

      expect(result).to be_ok
      monitor = result.value
      expect(monitor.project).to eq(project)
      expect(monitor.environment).to eq(environment)
      expect(monitor.created_by).to eq(actor)
      expect(monitor.name).to eq([ project.name, environment.label ].join(" · "))
    end

    it "environment NON dichiarato dal progetto → cade su nil → Result.err R422-MONITOR-001" do
      other_env = create(:environment, organization:) # non dichiarato da project

      result = described_class.call(monitor: Uptime::Monitor.new, attributes: valid_attributes,
                                    project:, environment_id: other_env.id, actor:)

      expect(result).to be_err
      expect(result.error.code).to eq("R422-MONITOR-001")
    end

    it "attributi invalidi (url assente) → Result.err con code e details" do
      result = described_class.call(monitor: Uptime::Monitor.new,
                                    attributes: valid_attributes.merge(url: ""),
                                    project:, environment_id: environment.id, actor:)

      expect(result).to be_err
      expect(result.error.code).to eq("R422-MONITOR-001")
      expect(result.error.details).to have_key(:url)
    end

    it "nuovo monitor SENZA progetto → environment resta nil (nil-safe) → Result.err" do
      result = described_class.call(monitor: Uptime::Monitor.new, attributes: valid_attributes,
                                    project: nil, environment_id: environment.id, actor:)

      expect(result).to be_err
      expect(result.error.code).to eq("R422-MONITOR-001")
    end
  end

  describe "update" do
    it "mantiene project/environment immutabili e applica gli altri attributi" do
      monitor = create(:uptime_monitor, project:, environment:)
      original_project = monitor.project
      original_environment = monitor.environment

      result = described_class.call(monitor:, attributes: { interval_seconds: 120 })

      expect(result).to be_ok
      expect(monitor.reload.interval_seconds).to eq(120)
      expect(monitor.project).to eq(original_project)
      expect(monitor.environment).to eq(original_environment)
    end

    it "NON tocca project/environment anche se passati (sono immutabili dopo la creazione)" do
      monitor = create(:uptime_monitor, project:, environment:)
      other_project = create(:project, organization:)

      result = described_class.call(monitor:, attributes: { interval_seconds: 90 },
                                    project: other_project, environment_id: create(:environment, organization:).id)

      expect(result).to be_ok
      expect(monitor.reload.project).to eq(project)
    end

    it "validazione fallita → Result.err R422-MONITOR-001" do
      monitor = create(:uptime_monitor, project:, environment:)

      result = described_class.call(monitor:, attributes: { url: "" })

      expect(result).to be_err
      expect(result.error.code).to eq("R422-MONITOR-001")
    end
  end
end
