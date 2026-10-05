# frozen_string_literal: true

require "rails_helper"

RSpec.describe Servers::ForecastJob, type: :job do
  include ActiveJob::TestHelper

  let(:host) { create(:server_host, status: :up) }

  def stub_forecast(value)
    allow(Servers::DiskForecast).to receive(:call).and_return(Result.ok(value))
  end

  it "stima sotto soglia → server_disk_forecast una volta sola, con memoria sull'host" do
    stub_forecast({ days: 9.5, slope_pct_per_day: 2.0, current_pct: 81.0 })
    host

    expect { described_class.perform_now }
      .to have_enqueued_job(Alerting::EvaluateJob)
      .with(hash_including(event_type: "server_disk_forecast", subject_id: host.id, value: 9.5))

    expect(host.reload.disk_forecast_state["alerted_at"]).to be_present

    # Secondo giro con stima ancora bassa: la memoria impedisce il bis.
    expect { described_class.perform_now }
      .not_to have_enqueued_job(Alerting::EvaluateJob)
      .with(hash_including(event_type: "server_disk_forecast"))
  end

  it "stima sopra la soglia di riarmo → stato azzerato, il prossimo peggioramento riavvisa" do
    host.update!(disk_forecast_state: { "days" => 9.5, "alerted_at" => 1.day.ago.iso8601 })
    stub_forecast({ days: 40.0, slope_pct_per_day: 0.3, current_pct: 70.0 })

    described_class.perform_now
    expect(host.reload.disk_forecast_state).to eq({})
  end

  it "stima fra allarme e riarmo → memoria conservata, nessun nuovo avviso" do
    host.update!(disk_forecast_state: { "days" => 9.5, "alerted_at" => 1.day.ago.iso8601 })
    stub_forecast({ days: 17.0, slope_pct_per_day: 1.5, current_pct: 75.0 })

    expect { described_class.perform_now }
      .not_to have_enqueued_job(Alerting::EvaluateJob)
    expect(host.reload.disk_forecast_state["alerted_at"]).to be_present
    expect(host.reload.disk_forecast_state["days"]).to eq(17.0)
  end

  it "nessuna stima → stato pulito e niente avvisi" do
    host.update!(disk_forecast_state: { "days" => 9.5, "alerted_at" => 1.day.ago.iso8601 })
    stub_forecast(nil)

    expect { described_class.perform_now }.not_to have_enqueued_job(Alerting::EvaluateJob)
    expect(host.reload.disk_forecast_state).to eq({})
  end
end
