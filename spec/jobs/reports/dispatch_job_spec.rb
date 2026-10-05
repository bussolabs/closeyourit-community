# frozen_string_literal: true

require "rails_helper"

# CYRA-160 — il giro che chiede, ogni giorno, chi deve ricevere il riepilogo dei dati. La cadenza
# vera la decide la preferenza di ciascuno: qui si presidia che non parta a nessun altro.
RSpec.describe Reports::DispatchJob, type: :job do
  let(:organization) { create(:organization) }
  let(:account) { create(:account) }
  let(:lunedi) { Time.zone.local(2026, 8, 10, 8, 0) }

  def preference(**attrs)
    create(:alerting_preference, account: create(:account), organization: organization, **attrs)
  end

  it "accoda il riepilogo per chi lo ha chiesto e non è ancora stato spedito" do
    pref = preference(report_cadence: :weekly)

    expect { travel_to(lunedi) { described_class.perform_now } }
      .to have_enqueued_job(Reports::DeliverJob).with(pref.id).once
  end

  it "chi non lo ha chiesto resta fuori" do
    preference(report_cadence: :off)

    expect { travel_to(lunedi) { described_class.perform_now } }
      .not_to have_enqueued_job(Reports::DeliverJob)
  end

  it "chi lo ha già ricevuto in questo periodo non lo riceve due volte" do
    preference(report_cadence: :weekly, report_last_sent_at: lunedi - 1.hour)

    expect { travel_to(lunedi) { described_class.perform_now } }
      .not_to have_enqueued_job(Reports::DeliverJob)
  end

  it "con le email spente non parte niente" do
    preference(report_cadence: :daily, email_enabled: false)

    expect { travel_to(lunedi) { described_class.perform_now } }
      .not_to have_enqueued_job(Reports::DeliverJob)
  end

  it "è schedulato nel recurring di produzione" do
    schedule = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true).fetch("production")
    entry = schedule.fetch("dispatch_data_reports")

    expect(entry["class"]).to eq(described_class.name)
    expect(entry["queue"]).to eq("notifications")
  end
end
