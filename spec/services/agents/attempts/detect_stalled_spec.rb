# frozen_string_literal: true

require "rails_helper"

# CYRA-212 Scenario 2: con le macchine attive ma per un'ora nessuna lavorazione conclusa, il sistema gira a
# vuoto e nessuno se ne accorge. DetectStalled rileva la condizione per org e accoda l'allarme org-scoped
# `agents_stalled`. Il segnale è l'ASSENZA DI PROGRESSO (nessun `approved` nella finestra) unita a lavoro
# sprecato (tentativi chiusi senza successo), non la durata dei running — che entro il TTL di 1h delle fasi
# possono essere ancora legittimi.
RSpec.describe Agents::Attempts::DetectStalled do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  let(:now) { Time.current }
  let(:window) { Agents::Constants::STALL_WINDOW }

  def online_host(org: organization, at: now)
    create(:agent_host, organization: org, last_heartbeat_at: at)
  end

  # Un tentativo chiuso SENZA successo (default: orfano potato da MarkStale) dentro la finestra.
  def wasted_attempt(org: organization, status: :stale, finished_ago: 10.minutes)
    create(:agent_attempt, organization: org, workflow: create(:agent_workflow, organization: org),
                           status:, started_at: now - 2.hours, finished_at: now - finished_ago)
  end

  def run = described_class.call(now:)

  describe "segnala l'org che gira a vuoto" do
    it "accoda agents_stalled con host attivo, lavoro sprecato nella finestra e nessun progresso" do
      online_host
      wasted_attempt

      expect { run }.to have_enqueued_job(Alerting::EvaluateJob).with(
        hash_including(event_type: "agents_stalled", subject_type: "Organizations::Organization",
                       subject_id: organization.id, organization_id: organization.id, project_id: nil)
      )
      expect(described_class.call(now:).value).to eq(1)
    end

    it "vale per gli esiti di spreco del sistema (fallito, review fallita), non solo per gli orfani" do
      online_host
      wasted_attempt(status: :review_failed)

      expect(run.value).to eq(1)
    end
  end

  describe "distingue lo spreco di sistema dalle decisioni umane" do
    # cancelled (Workflows::Cancel) e rejected (rifiuto umano) sono esiti VOLONTARI: dopo un annullamento o
    # una bocciatura normale il sistema non gira a vuoto, quindi non deve scattare l'allarme.
    it "tace se l'unico esito nella finestra è un annullamento volontario" do
      online_host
      wasted_attempt(status: :cancelled)

      expect { run }.not_to have_enqueued_job(Alerting::EvaluateJob)
      expect(run.value).to eq(0)
    end

    it "tace se l'unico esito nella finestra è un rifiuto umano" do
      online_host
      wasted_attempt(status: :rejected)

      expect { run }.not_to have_enqueued_job(Alerting::EvaluateJob)
    end
  end

  describe "non genera falsi allarmi" do
    it "tace se nessun host è online (macchina spenta: è lo Scenario 1 + il badge stalled, non questo)" do
      online_host(at: now - 3.hours)
      wasted_attempt

      expect { run }.not_to have_enqueued_job(Alerting::EvaluateJob)
      expect(run.value).to eq(0)
    end

    it "tace se il sistema progredisce: un tentativo approvato entro la finestra" do
      online_host
      wasted_attempt
      create(:agent_attempt, organization:, workflow: create(:agent_workflow, organization:),
                             status: :approved, started_at: now - 90.minutes, finished_at: now - 5.minutes)

      expect { run }.not_to have_enqueued_job(Alerting::EvaluateJob)
    end

    it "tace se nella finestra non c'è lavoro sprecato (coda tranquilla o tentativi ancora in corso)" do
      online_host
      create(:agent_attempt, organization:, workflow: create(:agent_workflow, organization:),
                             status: :running, started_at: now - 20.minutes)

      expect { run }.not_to have_enqueued_job(Alerting::EvaluateJob)
    end

    it "ignora il lavoro sprecato più vecchio della finestra" do
      online_host
      wasted_attempt(finished_ago: window + 30.minutes)

      expect { run }.not_to have_enqueued_job(Alerting::EvaluateJob)
    end
  end

  describe "isolamento per organizzazione" do
    it "segnala solo l'org ferma, non un'altra org solo perché ha host attivi" do
      online_host
      wasted_attempt
      other = create(:organization)
      online_host(org: other)

      expect(run.value).to eq(1)
      expect { described_class.call(now:) }.to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(subject_id: organization.id)).exactly(:once)
    end
  end
end
