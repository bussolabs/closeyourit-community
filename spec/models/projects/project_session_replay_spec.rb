# frozen_string_literal: true

require "rails_helper"

RSpec.describe Projects::Project, "capability session replay", type: :model do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }

  def platform(supports_session_replay:)
    create(:platform, organization:, supports_session_replay:)
  end

  it "supports_session_replay? è true solo con almeno una piattaforma capable (web)" do
    expect(project.supports_session_replay?).to be(false)

    project.platforms << platform(supports_session_replay: false)
    expect(project.reload.supports_session_replay?).to be(false)

    project.platforms << platform(supports_session_replay: true)
    expect(project.reload.supports_session_replay?).to be(true)
  end

  it ".session_replay_capable include solo i progetti con piattaforma capable" do
    capable = create(:project, organization:)
    capable.platforms << platform(supports_session_replay: true)
    project.platforms << platform(supports_session_replay: false)

    expect(described_class.session_replay_capable).to include(capable)
    expect(described_class.session_replay_capable).not_to include(project)
  end

  it "session_replay_enabled ha default false (opt-in)" do
    expect(create(:project, organization:).session_replay_enabled).to be(false)
  end

  it ".session_replay_collecting = capability web E toggle session_replay_enabled attivo" do
    capable_on  = create(:project, organization:, session_replay_enabled: true).tap  { |p| p.platforms << platform(supports_session_replay: true) }
    capable_off = create(:project, organization:, session_replay_enabled: false).tap { |p| p.platforms << platform(supports_session_replay: true) }
    plain_on    = create(:project, organization:, session_replay_enabled: true).tap  { |p| p.platforms << platform(supports_session_replay: false) }

    expect(described_class.session_replay_collecting).to include(capable_on)
    expect(described_class.session_replay_collecting).not_to include(capable_off, plain_on)
  end

  it "InstallDefaults: solo il web è session-replay-capable" do
    Types::InstallDefaults.call(organization:)

    expect(organization.platforms.find_by(code: "web").supports_session_replay).to be(true)
    expect(organization.platforms.find_by(code: "ios").supports_session_replay).to be(false)
    expect(organization.platforms.find_by(code: "android").supports_session_replay).to be(false)
  end
end
