# frozen_string_literal: true

require "rails_helper"

# CYRA-282: una quota di fallimenti anomala su UN host deve generare un avviso. È diverso da agents_stalled
# (org-scoped, zero progressi): il caso reale — una macchina con l'88% dei tentativi falliti mentre l'altra
# lavorava — NON scatterebbe l'allarme org, che tace se anche un solo host progredisce. Qui si guarda la
# QUOTA di fallimenti per host nella finestra, con un volume minimo sotto cui la quota non dice niente.
RSpec.describe Agents::Attempts::DetectFailingHosts do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  let(:now) { Time.current }
  let(:window) { Agents::Constants::HOST_FAILURE_WINDOW }
  let(:min) { Agents::Constants::HOST_FAILURE_MIN }

  def attempts_for(host, status:, count:, finished_ago: 10.minutes)
    count.times do
      create(:agent_attempt, organization: host.organization, host:,
                             workflow: create(:agent_workflow, organization: host.organization),
                             status:, started_at: now - 2.hours, finished_at: now - finished_ago)
    end
  end

  def run = described_class.call(now:)

  describe "segnala l'host che butta via il lavoro" do
    it "accoda agents_host_failing quando i fallimenti superano quota e volume minimo" do
      host = create(:agent_host, organization:)
      attempts_for(host, status: :failed, count: min)

      expect { run }.to have_enqueued_job(Alerting::EvaluateJob).with(
        hash_including(event_type: "agents_host_failing", subject_type: "Agents::Host",
                       subject_id: host.id, organization_id: organization.id, project_id: nil)
      )
      expect(described_class.call(now:).value).to eq(1)
    end

    it "conta i soli `failed`: bocciature e orfani non sono guasti della macchina" do
      host = create(:agent_host, organization:)
      attempts_for(host, status: :review_failed, count: min)
      attempts_for(host, status: :stale, count: min)

      expect { run }.not_to have_enqueued_job(Alerting::EvaluateJob)
    end
  end

  describe "non genera falsi allarmi" do
    it "tace sotto il volume minimo, anche se sono tutti falliti" do
      host = create(:agent_host, organization:)
      attempts_for(host, status: :failed, count: min - 1)

      expect { run }.not_to have_enqueued_job(Alerting::EvaluateJob)
      expect(run.value).to eq(0)
    end

    it "tace se la quota è bassa: tanti fallimenti ma il grosso del lavoro riesce" do
      host = create(:agent_host, organization:)
      attempts_for(host, status: :failed, count: min)
      attempts_for(host, status: :approved, count: min * 4)

      expect { run }.not_to have_enqueued_job(Alerting::EvaluateJob)
    end

    it "ignora i fallimenti più vecchi della finestra" do
      host = create(:agent_host, organization:)
      attempts_for(host, status: :failed, count: min, finished_ago: window + 30.minutes)

      expect { run }.not_to have_enqueued_job(Alerting::EvaluateJob)
    end

    it "non segnala un host revocato" do
      host = create(:agent_host, :revoked, organization:)
      attempts_for(host, status: :failed, count: min)

      expect { run }.not_to have_enqueued_job(Alerting::EvaluateJob)
    end
  end

  describe "isolamento per host" do
    it "segnala solo la macchina guasta, non quella sana della stessa org" do
      broken = create(:agent_host, organization:, hostname: "minion-1")
      healthy = create(:agent_host, organization:, hostname: "server-minion-1")
      attempts_for(broken, status: :failed, count: min)
      attempts_for(healthy, status: :approved, count: min)

      expect(run.value).to eq(1)
      expect { described_class.call(now:) }.to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(subject_id: broken.id)).exactly(:once)
    end
  end
end
