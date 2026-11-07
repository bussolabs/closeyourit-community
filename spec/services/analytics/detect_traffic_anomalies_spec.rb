# frozen_string_literal: true

require "rails_helper"

# CYRA-147 — rilevamento crollo/picco di traffico. min_baseline è iniettato piccolo per testare la LOGICA
# senza seminare centinaia di pageview; le soglie di produzione vivono in App::Constants.
# CYRA-1116 — la baseline è la media della stessa fascia oraria nei giorni precedenti, non più una media
# piatta sulle 24h.
RSpec.describe Analytics::DetectTrafficAnomalies, type: :service do
  include ActiveJob::TestHelper

  let(:now) { Time.zone.local(2026, 8, 7, 12, 0, 0) }
  let(:org) { create(:organization) }
  let(:web) { Types::Platform.find_by!(organization: org, code: "web") }
  # Progetto che RACCOGLIE analytics: piattaforma web (capable) + toggle attivo.
  let(:project) { create(:project, organization: org, analytics_enabled: true).tap { |p| p.platforms << web } }

  before { Types::InstallDefaults.call(organization: org) }

  # Baseline: per_day pageview nella stessa fascia oraria (l'ora prima di at) di ciascuno dei 7 giorni
  # precedenti → per_day visite attese.
  def seed_same_slot(per_day, at: now)
    (1..Analytics::Constants::TRAFFIC_BASELINE_DAYS).each do |days_ago|
      create_list(:pageview, per_day, project: project, occurred_at: at - days_ago.days - 30.minutes)
    end
  end

  def seed_current(count, at: now)
    create_list(:pageview, count, project: project, occurred_at: at - 30.minutes) if count.positive?
  end

  it "non avvisa di notte se le visite sono in linea con la stessa ora dei giorni prima" do
    night = Time.zone.local(2026, 8, 7, 3, 0, 0)
    seed_same_slot(1, at: night)
    # Ieri a mezzogiorno il sito era pieno: con la vecchia media piatta sulle 24h (~4/ora) l'unica
    # visita delle 2-3 di notte sarebbe sembrata un crollo.
    create_list(:pageview, 96, project: project, occurred_at: night - 15.hours)
    seed_current(1, at: night)

    expect { described_class.call(now: night, min_baseline: 1) }.not_to have_enqueued_job(Alerting::EvaluateJob)
  end

  it "accoda un allarme di crollo quando l'ultima ora è molto sotto la stessa ora dei giorni prima" do
    seed_same_slot(4)
    seed_current(1) # 1 <= 4 * DROP_RATIO

    expect { described_class.call(now: now, min_baseline: 1) }
      .to have_enqueued_job(Alerting::EvaluateJob).with(
        hash_including(event_type: "analytics_traffic_drop", subject_type: "Projects::Project",
                       subject_id: project.id, project_id: project.id)
      )
  end

  it "accoda un allarme di picco quando l'ultima ora esplode sopra la stessa ora dei giorni prima" do
    seed_same_slot(2)
    seed_current(8) # 8 >= 2 * SPIKE_RATIO

    expect { described_class.call(now: now, min_baseline: 1) }
      .to have_enqueued_job(Alerting::EvaluateJob).with(hash_including(event_type: "analytics_traffic_spike"))
  end

  it "non accoda nulla con traffico nella norma" do
    seed_same_slot(2)
    seed_current(2) # = baseline: né crollo né picco

    expect { described_class.call(now: now, min_baseline: 1) }.not_to have_enqueued_job(Alerting::EvaluateJob)
  end

  it "non conta le visite fuori dalla stessa fascia oraria dei giorni prima" do
    # Visite nei giorni precedenti ma in altre ore: la fascia delle 11-12 resta vuota → nessun verdetto.
    seed_same_slot(4, at: now - 3.hours)

    expect { described_class.call(now: now, min_baseline: 1) }.not_to have_enqueued_job(Alerting::EvaluateJob)
  end

  it "non dà alcun verdetto se le visite attese in quella ora sono sotto la soglia minima" do
    seed_same_slot(1) # 1 attesa, ma min_baseline = 2 → troppo poco per giudicare

    expect { described_class.call(now: now, min_baseline: 2) }.not_to have_enqueued_job(Alerting::EvaluateJob)

    seed_current(50) # nemmeno un picco
    expect { described_class.call(now: now, min_baseline: 2) }.not_to have_enqueued_job(Alerting::EvaluateJob)
  end

  it "ignora i progetti che non raccolgono analytics" do
    create(:project, organization: org, analytics_enabled: false)

    expect { described_class.call(now: now, min_baseline: 1) }.not_to have_enqueued_job(Alerting::EvaluateJob)
  end
end
