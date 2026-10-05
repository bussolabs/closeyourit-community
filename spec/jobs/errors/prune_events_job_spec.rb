# frozen_string_literal: true

require "rails_helper"

RSpec.describe Errors::PruneEventsJob, type: :job do
  before { Settings::Global.instance.update!(errors_retention_days: 30) }

  it "cancella gli eventi oltre la soglia di sistema, tiene i recenti" do
    travel_to(Time.utc(2026, 6, 30, 12)) do
      group = create(:error_group, events_count: 2)
      old_event = create(:error_event, group:, project: group.project, created_at: 31.days.ago)
      recent = create(:error_event, group:, project: group.project, created_at: 1.day.ago)

      described_class.perform_now

      expect(Errors::Event.exists?(old_event.id)).to be(false)
      expect(Errors::Event.exists?(recent.id)).to be(true)
    end
  end

  it "rispetta l'override per-progetto (A 7g potato vs B 30g tenuto, nearest-wins)" do
    a = create(:project).tap { |p| p.update!(errors_retention_days: 7) }
    b = create(:project).tap { |p| p.update!(errors_retention_days: 30) }
    group_a = create(:error_group, project: a)
    group_b = create(:error_group, project: b)
    event_a = create(:error_event, group: group_a, project: a, created_at: 10.days.ago)
    event_b = create(:error_event, group: group_b, project: b, created_at: 10.days.ago)

    described_class.perform_now

    expect(Errors::Event.exists?(event_a.id)).to be(false)
    expect(Errors::Event.exists?(event_b.id)).to be(true)
  end

  it "applica la retention dell'org quando il progetto non ha override" do
    org = create(:organization).tap { |o| o.update!(errors_retention_days: 5) }
    project = create(:project, organization: org)
    group = create(:error_group, project:)
    old_event = create(:error_event, group:, project:, created_at: 8.days.ago)
    fresh_event = create(:error_event, group:, project:, created_at: 2.days.ago)

    described_class.perform_now

    expect(Errors::Event.exists?(old_event.id)).to be(false)
    expect(Errors::Event.exists?(fresh_event.id)).to be(true)
  end

  it "usa il default di sistema (30g) quando né progetto né org né god impostano una retention" do
    Settings::Global.instance.update!(errors_retention_days: Errors::Constants::RETENTION_DEFAULT_DAYS)
    group = create(:error_group)
    just_old = create(:error_event, group:, project: group.project,
                                    created_at: Errors::Constants::RETENTION_DEFAULT_DAYS.days.ago - 1.second)
    just_new = create(:error_event, group:, project: group.project,
                                    created_at: Errors::Constants::RETENTION_DEFAULT_DAYS.days.ago + 1.second)

    described_class.perform_now

    expect(Errors::Event.exists?(just_old.id)).to be(false)
    expect(Errors::Event.exists?(just_new.id)).to be(true)
  end

  it "il gruppo e i suoi contatori sopravvivono alla potatura" do
    group = create(:error_group, events_count: 3)
    create(:error_event, group:, project: group.project, created_at: 40.days.ago)
    described_class.perform_now
    expect(Errors::Group.exists?(group.id)).to be(true)
    expect(group.reload.events_count).to eq(3) # i contatori non vengono decrementati
  end

  it "risolve Settings::Global una sola volta (no N+1 sul singleton)" do
    create_list(:project, 3).each { |p| create(:error_event, group: create(:error_group, project: p), project: p) }
    expect(Settings::Global).to receive(:instance).once.and_call_original
    described_class.perform_now
  end
end
