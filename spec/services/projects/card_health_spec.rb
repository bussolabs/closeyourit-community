# frozen_string_literal: true

require "rails_helper"

RSpec.describe Projects::CardHealth do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:other) { create(:project, organization: org) }

  subject(:health) { described_class.new([ project, other ]) }

  describe "#errors_for" do
    it "counts only unresolved error groups of each project" do
      create_list(:error_group, 2, project:)
      create(:error_group, :resolved, project:)

      expect(health.errors_for(project)).to eq(2)
      expect(health.errors_for(other)).to eq(0)
    end
  end

  describe "#uptime_for" do
    it "is nil when the project has no active monitor" do
      create(:uptime_monitor, :up, :paused, project:, last_checked_at: Time.current)

      expect(health.uptime_for(project)).to be_nil
    end

    it "is down when any fresh monitor is down, even if another is up" do
      create(:uptime_monitor, :up, project:, last_checked_at: Time.current)
      create(:uptime_monitor, :down, project:, last_checked_at: Time.current)

      expect(health.uptime_for(project)).to eq(:down)
    end

    it "is up when every fresh monitor is up" do
      create(:uptime_monitor, :up, project:, last_checked_at: Time.current)

      expect(health.uptime_for(project)).to eq(:up)
    end

    it "is unknown when one monitor is up and another has a stale result" do
      create(:uptime_monitor, :up, project:, last_checked_at: Time.current)
      create(:uptime_monitor, :up, project:, last_checked_at: 3.days.ago)

      expect(health.uptime_for(project)).to eq(:unknown)
    end

    it "is unknown when the only monitor has a stale result" do
      create(:uptime_monitor, :up, project:, last_checked_at: 3.days.ago)

      expect(health.uptime_for(project)).to eq(:unknown)
    end
  end

  describe "#release_for" do
    it "returns the most recent release of each project" do
      create(:release, project:, version: "v1.0.0", created_at: 2.days.ago)
      latest = create(:release, project:, version: "v1.1.0", created_at: 1.hour.ago)

      expect(health.release_for(project)).to eq(latest)
      expect(health.release_for(other)).to be_nil
    end
  end

  it "reads each domain once for the whole list" do
    create(:error_group, project:)
    create(:release, project:)
    health # builds the projects outside the measured block

    queries = 0
    counter = ->(*, payload) { queries += 1 unless payload[:name] == "SCHEMA" || payload[:cached] }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      [ project, other ].each { |p| health.errors_for(p); health.uptime_for(p); health.release_for(p) }
    end

    expect(queries).to eq(3)
  end
end
