# frozen_string_literal: true

require "rails_helper"

RSpec.describe Projects::Project, "capability analytics", type: :model do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }

  def platform(supports_analytics:)
    create(:platform, organization:, supports_analytics:)
  end

  it "supports_analytics? è true solo con almeno una piattaforma analytics-capable" do
    expect(project.supports_analytics?).to be(false)

    project.platforms << platform(supports_analytics: false)
    expect(project.reload.supports_analytics?).to be(false)

    project.platforms << platform(supports_analytics: true)
    expect(project.reload.supports_analytics?).to be(true)
  end

  it ".analytics_capable include solo i progetti con piattaforma analytics-capable" do
    capable = create(:project, organization:)
    capable.platforms << platform(supports_analytics: true)
    project.platforms << platform(supports_analytics: false)

    expect(described_class.analytics_capable).to include(capable)
    expect(described_class.analytics_capable).not_to include(project)
  end

  it "analytics_enabled ha default false (opt-in)" do
    expect(create(:project, organization:).analytics_enabled).to be(false)
  end

  it ".analytics_collecting = capability web E toggle analytics_enabled attivo (4 confini)" do
    capable_on  = create(:project, organization:, analytics_enabled: true).tap  { |p| p.platforms << platform(supports_analytics: true) }
    capable_off = create(:project, organization:, analytics_enabled: false).tap { |p| p.platforms << platform(supports_analytics: true) }
    plain_on    = create(:project, organization:, analytics_enabled: true).tap  { |p| p.platforms << platform(supports_analytics: false) }
    plain_off   = create(:project, organization:, analytics_enabled: false)

    expect(described_class.analytics_collecting).to include(capable_on)
    expect(described_class.analytics_collecting).not_to include(capable_off, plain_on, plain_off)
  end

  it "valida analytics_retention_days ai confini (1..730)" do
    expect(build(:project, organization:, analytics_retention_days: 0)).not_to be_valid
    expect(build(:project, organization:, analytics_retention_days: 1)).to be_valid
    expect(build(:project, organization:, analytics_retention_days: 730)).to be_valid
    expect(build(:project, organization:, analytics_retention_days: 731)).not_to be_valid
    expect(build(:project, organization:, analytics_retention_days: nil)).to be_valid
  end
end
