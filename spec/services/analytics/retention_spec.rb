# frozen_string_literal: true

require "rails_helper"

RSpec.describe Analytics::Retention do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }

  it "uses the system default when the resolved global value is absent" do
    Settings::Global.instance.update!(analytics_retention_days: 200)
    # An explicitly resolved nil must not reread the required global setting.
    expect(described_class.for(project, global_days: nil))
      .to eq(Analytics::Constants::RETENTION_DEFAULT_DAYS)
  end

  it "prefers the global value over the system default" do
    expect(described_class.for(project, global_days: 500)).to eq(500)
  end

  it "prefers the organization value over the global value" do
    organization.update!(analytics_retention_days: 90)
    expect(described_class.for(project, global_days: 500)).to eq(90)
  end

  it "prefers the project value over every inherited value" do
    organization.update!(analytics_retention_days: 90)
    project.update!(analytics_retention_days: 30)
    expect(described_class.for(project, global_days: 500)).to eq(30)
  end

  it "reads the global singleton when no resolved value is supplied" do
    Settings::Global.instance.update!(analytics_retention_days: 200)
    expect(described_class.for(project)).to eq(200)
  end

  describe ".resolve" do
    it "returns a positive integer or nil for inherited values" do
      expect(described_class.resolve(10)).to eq(10)
      expect(described_class.resolve("15")).to eq(15)
      expect(described_class.resolve(0)).to be_nil
      expect(described_class.resolve(nil)).to be_nil
      expect(described_class.resolve("")).to be_nil
    end
  end
end
