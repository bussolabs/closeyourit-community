# frozen_string_literal: true

require "rails_helper"

RSpec.describe Settings::Global, type: :model do
  describe ".instance" do
    it "creates the default row on first access" do
      # Transactional fixtures restore any preexisting singleton after this example.
      described_class.delete_all
      expect { described_class.instance }.to change(described_class, :count).by(1)
      expect(described_class.instance.logs_retention_days)
        .to eq(Logs::Constants::RETENTION_DEFAULT_DAYS)
      expect(described_class.instance.analytics_retention_days)
        .to eq(Analytics::Constants::RETENTION_DEFAULT_DAYS)
      expect(described_class.instance.errors_retention_days)
        .to eq(Errors::Constants::RETENTION_DEFAULT_DAYS)
      expect(described_class.instance.performance_retention_days)
        .to eq(Metrics::Constants::RETENTION_DEFAULT_DAYS)
      expect(described_class.instance.servers_retention_days)
        .to eq(Servers::Constants::RETENTION_DEFAULT_DAYS)
      expect(described_class.instance.uptime_retention_days)
        .to eq(Uptime::Constants::RETENTION_DEFAULT_DAYS)
    end

    it "reuses the existing row idempotently" do
      first = described_class.instance
      expect { described_class.instance }.not_to change(described_class, :count)
      expect(described_class.instance).to eq(first)
    end
  end

  it "requires logs_retention_days between 1 and 365" do
    expect(build(:settings_global, logs_retention_days: 0)).not_to be_valid
    expect(build(:settings_global, logs_retention_days: 366)).not_to be_valid
    expect(build(:settings_global, logs_retention_days: 1)).to be_valid
    expect(build(:settings_global, logs_retention_days: 365)).to be_valid
    expect(build(:settings_global, logs_retention_days: nil)).not_to be_valid
  end

  it "requires analytics_retention_days between 1 and 730" do
    expect(build(:settings_global, analytics_retention_days: 0)).not_to be_valid
    expect(build(:settings_global, analytics_retention_days: 731)).not_to be_valid
    expect(build(:settings_global, analytics_retention_days: 1)).to be_valid
    expect(build(:settings_global, analytics_retention_days: 730)).to be_valid
    expect(build(:settings_global, analytics_retention_days: nil)).not_to be_valid
  end

  it "requires errors_retention_days between 1 and 365" do
    expect(build(:settings_global, errors_retention_days: 0)).not_to be_valid
    expect(build(:settings_global, errors_retention_days: 366)).not_to be_valid
    expect(build(:settings_global, errors_retention_days: 1)).to be_valid
    expect(build(:settings_global, errors_retention_days: 365)).to be_valid
    expect(build(:settings_global, errors_retention_days: nil)).not_to be_valid
  end

  it "requires performance_retention_days between 1 and 365" do
    expect(build(:settings_global, performance_retention_days: 0)).not_to be_valid
    expect(build(:settings_global, performance_retention_days: 366)).not_to be_valid
    expect(build(:settings_global, performance_retention_days: 1)).to be_valid
    expect(build(:settings_global, performance_retention_days: 365)).to be_valid
    expect(build(:settings_global, performance_retention_days: nil)).not_to be_valid
  end

  it "requires servers_retention_days between 1 and 365" do
    expect(build(:settings_global, servers_retention_days: 0)).not_to be_valid
    expect(build(:settings_global, servers_retention_days: 366)).not_to be_valid
    expect(build(:settings_global, servers_retention_days: 1)).to be_valid
    expect(build(:settings_global, servers_retention_days: 365)).to be_valid
    expect(build(:settings_global, servers_retention_days: nil)).not_to be_valid
  end

  it "requires uptime_retention_days between 1 and 730" do
    expect(build(:settings_global, uptime_retention_days: 0)).not_to be_valid
    expect(build(:settings_global, uptime_retention_days: 731)).not_to be_valid
    expect(build(:settings_global, uptime_retention_days: 1)).to be_valid
    expect(build(:settings_global, uptime_retention_days: 730)).to be_valid
    expect(build(:settings_global, uptime_retention_days: nil)).not_to be_valid
  end
end
