# frozen_string_literal: true

require "rails_helper"

# Decadimento realtime: il job ri-broadcasta i progetti con pageview recenti (entro la finestra
# realtime + 1min di margine), così il chip "visitatori online" scende quando il traffico cessa.
# Oltre la finestra un progetto non viene più toccato (l'ultimo refresh ha già azzerato il chip).
RSpec.describe Analytics::DecayRealtimeJob, type: :job do
  def stream_for(project) = Realtime::Streams.analytics(project)

  it "broadcasta un page-refresh per il progetto con pageview recente" do
    project = create(:project)
    create(:pageview, project:, occurred_at: 1.minute.ago)

    expect { described_class.perform_now }
      .to have_broadcasted_to(stream_for(project)).with(a_string_including('action="refresh"'))
  end

  it "NON broadcasta per un progetto la cui attività è oltre la finestra realtime" do
    project = create(:project)
    create(:pageview, project:, occurred_at: (Analytics::Constants::REALTIME_WINDOW + 10.minutes).ago)

    expect { described_class.perform_now }.not_to have_broadcasted_to(stream_for(project))
  end

  it "bounds the scan by created_at so old monthly partitions are skipped (CYRA-891)" do
    sql = []
    callback = ->(*, payload) { sql << payload[:sql] if payload[:sql].include?("analytics_pageviews") }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { described_class.perform_now }

    expect(sql.first).to include('"created_at" >=')
  end

  it "still sees a pageview from a client whose clock runs ahead" do
    project = create(:project)
    create(:pageview, project:, occurred_at: 1.minute.ago, created_at: 50.minutes.ago)

    expect { described_class.perform_now }.to have_broadcasted_to(stream_for(project))
  end

  it "nessun pageview → nessun broadcast (no-op)" do
    project = create(:project)

    expect { described_class.perform_now }.not_to have_broadcasted_to(stream_for(project))
  end

  it "isola i progetti attivi da quelli idle" do
    active = create(:project)
    idle = create(:project)
    create(:pageview, project: active, occurred_at: 30.seconds.ago)
    create(:pageview, project: idle, occurred_at: 20.minutes.ago)

    expect { described_class.perform_now }.to have_broadcasted_to(stream_for(active))
    expect { described_class.perform_now }.not_to have_broadcasted_to(stream_for(idle))
  end
end
