# frozen_string_literal: true

require "rails_helper"

# CYRA-147 — rilevamento crollo/picco di traffico. min_baseline è iniettato piccolo per testare la LOGICA
# senza seminare centinaia di pageview; le soglie di produzione vivono in App::Constants.
RSpec.describe Analytics::DetectTrafficAnomalies, type: :service do
  include ActiveJob::TestHelper

  let(:now) { Time.zone.local(2026, 8, 7, 12, 0, 0) }
  let(:org) { create(:organization) }
  let(:web) { Types::Platform.find_by!(organization: org, code: "web") }
  # Progetto che RACCOGLIE analytics: piattaforma web (capable) + toggle attivo.
  let(:project) { create(:project, organization: org, analytics_enabled: true).tap { |p| p.platforms << web } }

  before { Types::InstallDefaults.call(organization: org) }

  # Baseline: 24 pageview distribuiti nelle 24h precedenti l'ultima ora → 1 visita/ora.
  def seed_baseline
    create_list(:pageview, 24, project: project, occurred_at: now - 12.hours)
  end

  def seed_current(count)
    create_list(:pageview, count, project: project, occurred_at: now - 30.minutes)
  end

  it "accoda un allarme di crollo quando l'ultima ora è molto sotto la baseline" do
    seed_baseline # 1/ora, ultima ora = 0

    expect { described_class.call(now: now, min_baseline: 1) }
      .to have_enqueued_job(Alerting::EvaluateJob).with(
        hash_including(event_type: "analytics_traffic_drop", subject_type: "Projects::Project",
                       subject_id: project.id, project_id: project.id)
      )
  end

  it "accoda un allarme di picco quando l'ultima ora esplode sopra la baseline" do
    seed_baseline
    seed_current(10) # 10 >= 1 * SPIKE_RATIO

    expect { described_class.call(now: now, min_baseline: 1) }
      .to have_enqueued_job(Alerting::EvaluateJob).with(hash_including(event_type: "analytics_traffic_spike"))
  end

  it "non accoda nulla con traffico nella norma" do
    seed_baseline
    seed_current(1) # ~ baseline: né crollo né picco

    expect { described_class.call(now: now, min_baseline: 1) }.not_to have_enqueued_job(Alerting::EvaluateJob)
  end

  it "non dà alcun verdetto se il traffico storico è sotto la soglia minima" do
    seed_baseline # 1/ora, ma min_baseline = 2 → troppo poco per giudicare

    expect { described_class.call(now: now, min_baseline: 2) }.not_to have_enqueued_job(Alerting::EvaluateJob)
  end

  it "ignora i progetti che non raccolgono analytics" do
    create(:project, organization: org, analytics_enabled: false)

    expect { described_class.call(now: now, min_baseline: 1) }.not_to have_enqueued_job(Alerting::EvaluateJob)
  end
end
