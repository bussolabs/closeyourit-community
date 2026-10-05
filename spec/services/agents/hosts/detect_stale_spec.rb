# frozen_string_literal: true

require "rails_helper"

# CYRA-450: una macchina che non batte da oltre la soglia di allarme (offline + grazia) è "ferma" e va
# segnalata come qualunque altro controllo. Sola lettura: rende visibile un degrado altrimenti silenzioso.
RSpec.describe Agents::Hosts::DetectStale do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  let(:now) { Time.current }
  let(:after) { Agents::Constants::HOST_STALE_AFTER }

  def host(last_heartbeat_at:, **attrs)
    create(:agent_host, organization:, last_heartbeat_at:,
                        heartbeat_expected_interval_minutes: 2, heartbeat_grace_minutes: 1, **attrs)
  end

  def run = described_class.call(now:)

  describe "segnala l'host fermo" do
    it "accoda agents_host_stale per una macchina silente oltre la soglia" do
      dead = host(last_heartbeat_at: now - after - 1.minute, hostname: "mac-dead")

      expect { run }.to have_enqueued_job(Alerting::EvaluateJob).with(
        hash_including(event_type: "agents_host_stale", subject_type: "Agents::Host",
                       subject_id: dead.id, organization_id: organization.id, project_id: nil)
      )
      expect(run.value).to eq(1)
    end
  end

  describe "non genera falsi allarmi" do
    it "tace per una macchina online (battito recente)" do
      host(last_heartbeat_at: 30.seconds.ago)

      expect { run }.not_to have_enqueued_job(Alerting::EvaluateJob)
      expect(run.value).to eq(0)
    end

    it "tace per una macchina appena offline ma sotto la soglia (grazia anti-riavvio)" do
      host(last_heartbeat_at: now - after + 1.minute)

      expect { run }.not_to have_enqueued_job(Alerting::EvaluateJob)
    end

    it "non segnala un host revocato (dismesso, non un allarme da riaprire)" do
      host(last_heartbeat_at: now - after - 1.hour, revoked_at: now)

      expect { run }.not_to have_enqueued_job(Alerting::EvaluateJob)
    end
  end

  # CYRA-520 — nel caso reale sono arrivati 49 avvisi identici in due giorni, uno ogni ora: a quel
  # punto non li legge più nessuno. Il promemoria si dirada, e il gradino è "scoperto" finché per
  # questa macchina non è arrivato un avviso da quando il gradino è cominciato.
  describe "il promemoria si dirada" do
    def alerted_at(host, moment)
      create(:alerting_notification, organization:, subject: host,
                                     event_type: :agents_host_stale, created_at: moment)
    end

    it "il primo avviso parte comunque: non c'è niente da diradare" do
      host(last_heartbeat_at: now - after - 1.minute)

      expect { run }.to have_enqueued_job(Alerting::EvaluateJob)
    end

    it "tace se per questo gradino l'avviso è già arrivato" do
      fermo = host(last_heartbeat_at: now - after - 10.minutes)
      alerted_at(fermo, now - 5.minutes)

      expect { run }.not_to have_enqueued_job(Alerting::EvaluateJob)
    end

    it "torna a parlare al gradino dopo" do
      fermo = host(last_heartbeat_at: now - after - 70.minutes)
      alerted_at(fermo, now - 70.minutes) # avviso del gradino iniziale

      expect { run }.to have_enqueued_job(Alerting::EvaluateJob).with(hash_including(subject_id: fermo.id))
    end

    it "ferma da giorni, un promemoria al giorno e non uno all'ora" do
      fermo = host(last_heartbeat_at: now - after - 30.hours)
      alerted_at(fermo, now - 5.hours) # avviso del gradino delle 24 ore

      expect { run }.not_to have_enqueued_job(Alerting::EvaluateJob)
    end

    it "in due giorni fermi i gradini sono 7, non 49" do
      inizio = now - after
      fermo = host(last_heartbeat_at: inizio)
      avvisi = 0

      # Il controllo gira ogni 15 minuti: due giorni pieni sono 193 giri, dal minuto zero alla 48ª ora.
      193.times do |giro|
        istante = inizio + after + (giro * 15).minutes
        if described_class.call(now: istante).value.positive?
          avvisi += 1
          alerted_at(fermo, istante)
        end
      end

      expect(avvisi).to eq(7) # 0h, 1h, 3h, 6h, 12h, 24h, 48h
    end
  end

  describe "isolamento per host" do
    it "segnala solo la macchina ferma, non quella viva della stessa org" do
      dead = host(last_heartbeat_at: now - after - 1.minute, hostname: "mac-dead")
      host(last_heartbeat_at: 30.seconds.ago, hostname: "mac-alive")

      expect(run.value).to eq(1)
      expect { described_class.call(now:) }.to have_enqueued_job(Alerting::EvaluateJob)
        .with(hash_including(subject_id: dead.id)).exactly(:once)
    end
  end
end
