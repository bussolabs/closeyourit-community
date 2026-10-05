# frozen_string_literal: true

require "rails_helper"

RSpec.describe Servers::Host, type: :model do
  describe "validazioni" do
    it "è valido con organization, fingerprint e name" do
      expect(build(:server_host)).to be_valid
    end

    it "richiede il fingerprint" do
      expect(build(:server_host, fingerprint: nil)).not_to be_valid
    end

    it "rifiuta un fingerprint duplicato nella stessa organization" do
      existing = create(:server_host)
      dup = build(:server_host, organization: existing.organization, fingerprint: existing.fingerprint)

      expect(dup).not_to be_valid
      expect(dup.errors[:fingerprint]).to be_present
    end

    it "accetta lo stesso fingerprint in organization diverse" do
      existing = create(:server_host)

      expect(build(:server_host, fingerprint: existing.fingerprint)).to be_valid
    end

    it "richiede il name" do
      expect(build(:server_host, name: "")).not_to be_valid
    end

    it "normalizza name e hostname (strip, hostname vuoto → nil)" do
      host = build(:server_host, name: "  web-1  ", hostname: "   ")

      expect(host.name).to eq("web-1")
      expect(host.hostname).to be_nil
    end
  end

  describe "associazioni" do
    it "distrugge samples e container_samples alla destroy" do
      host = create(:server_host)
      create(:server_sample, host: host)
      create(:server_container_sample, host: host)

      expect { host.destroy! }
        .to change(Servers::Sample, :count).by(-1)
        .and change(Servers::ContainerSample, :count).by(-1)
    end
  end

  describe ".active" do
    it "esclude gli host revocati" do
      active = create(:server_host)
      revoked = create(:server_host, :revoked, organization: active.organization)

      expect(described_class.active).to include(active)
      expect(described_class.active).not_to include(revoked)
    end
  end

  describe ".with_database" do
    it "tiene solo gli host il cui snapshot porta l'elenco dei database" do
      with_databases = create(:server_host, database_snapshot: { "engine" => "postgresql",
                                                                 "databases" => [ { "name" => "app_production" } ] })
      org = with_databases.organization
      # Database rilevato ma non sondabile: nessun elenco, niente da inventariare.
      unreachable = create(:server_host, organization: org,
                           database_snapshot: { "engine" => "postgresql", "reachable" => false })
      without_database = create(:server_host, organization: org)

      expect(described_class.with_database).to contain_exactly(with_databases)
      expect(described_class.with_database).not_to include(unreachable, without_database)
    end
  end

  describe ".stale" do
    let(:now) { Time.zone.local(2026, 7, 2, 12, 0, 0) }
    let(:threshold) { Servers::Constants::STALE_AFTER_SECONDS }

    it "include l'host up silente da oltre la soglia (soglia + 1s)" do
      host = create(:server_host, status: :up, last_push_at: now - threshold.seconds - 1.second)

      expect(described_class.stale(now)).to include(host)
    end

    it "esclude l'host up esattamente alla soglia" do
      host = create(:server_host, status: :up, last_push_at: now - threshold.seconds)

      expect(described_class.stale(now)).not_to include(host)
    end

    it "esclude l'host up appena visto (soglia - 1s)" do
      host = create(:server_host, status: :up, last_push_at: now - threshold.seconds + 1.second)

      expect(described_class.stale(now)).not_to include(host)
    end

    it "esclude paused, down, pending e revocati anche se silenti" do
      silent = now - threshold.seconds - 1.minute
      paused = create(:server_host, status: :paused, last_push_at: silent)
      down = create(:server_host, status: :down, last_push_at: silent)
      pending = create(:server_host, status: :pending, last_push_at: silent)
      revoked = create(:server_host, :revoked, status: :up, last_push_at: silent)

      expect(described_class.stale(now)).not_to include(paused, down, pending, revoked)
    end

    it "esclude l'host up senza last_push_at" do
      host = create(:server_host, status: :up, last_push_at: nil)

      expect(described_class.stale(now)).not_to include(host)
    end

    # CYRA-649 — il falso positivo che ha svegliato 19 macchine ogni notte: gli agent pushavano
    # ogni 60s, ma la corsia di ricezione era in arretrato e last_seen_at (scritto dall'ingest, e
    # pari all'ora della fotografia) restava indietro di minuti. La salute si giudica su quando la
    # macchina ha PARLATO, non su quando siamo riusciti a scriverne i dati.
    it "esclude l'host che ha appena pushato anche se la sua fotografia è vecchia di un'ora" do
      host = create(:server_host, status: :up,
                    last_push_at: now - 10.seconds, last_seen_at: now - 1.hour)

      expect(described_class.stale(now)).not_to include(host)
    end

    it "include l'host silente anche se la sua ultima fotografia sembra recente (orologio avanti)" do
      host = create(:server_host, status: :up,
                    last_push_at: now - threshold.seconds - 1.minute, last_seen_at: now)

      expect(described_class.stale(now)).to include(host)
    end
  end

  describe "#revoked?" do
    it "è true solo con revoked_at presente" do
      expect(build(:server_host, :revoked).revoked?).to be(true)
      expect(build(:server_host).revoked?).to be(false)
    end
  end

  describe "#supports_action?" do
    it "consente le azioni senza versione minima a qualunque agent" do
      expect(build(:server_host, agent_version: nil).supports_action?("reboot")).to be(true)
    end

    it "consente apply_all_updates dalla 0.8.0 in su" do
      expect(build(:server_host, agent_version: "0.8.0").supports_action?("apply_all_updates")).to be(true)
      expect(build(:server_host, agent_version: "0.9.1").supports_action?("apply_all_updates")).to be(true)
    end

    it "nega apply_all_updates agli agent precedenti o con versione illeggibile" do
      expect(build(:server_host, agent_version: "0.7.0").supports_action?("apply_all_updates")).to be(false)
      expect(build(:server_host, agent_version: nil).supports_action?("apply_all_updates")).to be(false)
      expect(build(:server_host, agent_version: "boh").supports_action?("apply_all_updates")).to be(false)
    end
  end

  describe "#non_security_updates" do
    it "è la parte che gli aggiornamenti di sicurezza non toccano" do
      host = build(:server_host, updates_available: 15, security_updates_available: 0)

      expect(host.non_security_updates).to eq(15)
    end

    it "non scende sotto zero se i conteggi arrivano incoerenti" do
      host = build(:server_host, updates_available: 2, security_updates_available: 5)

      expect(host.non_security_updates).to eq(0)
    end

    it "è nil quando manca un conteggio (agent vecchio o distro non-apt)" do
      expect(build(:server_host, updates_available: 15, security_updates_available: nil).non_security_updates).to be_nil
      expect(build(:server_host, updates_available: nil, security_updates_available: 0).non_security_updates).to be_nil
    end
  end

  # CYRA-458: soglie d'allarme per-macchina delle metriche di occupazione (cpu/mem/disco).
  describe "soglie per-macchina" do
    it "è valido senza soglie (nil = vale la regola generale dell'org)" do
      expect(build(:server_host, cpu_threshold: nil, mem_threshold: nil, disk_threshold: nil)).to be_valid
    end

    it "accetta soglie fra 0 e 100" do
      expect(build(:server_host, cpu_threshold: 0, mem_threshold: 85, disk_threshold: 100)).to be_valid
    end

    it "rifiuta soglie fuori dall'intervallo percentuale" do
      expect(build(:server_host, cpu_threshold: -1)).not_to be_valid
      expect(build(:server_host, mem_threshold: 101)).not_to be_valid
    end

    it "una soglia vuota dal form diventa nil, non zero" do
      host = build(:server_host, disk_threshold: "")

      expect(host.disk_threshold).to be_nil
      expect(host).to be_valid
    end

    describe "#threshold_for" do
      it "mappa l'evento server alla soglia per-macchina della metrica" do
        host = build(:server_host, cpu_threshold: 70, mem_threshold: 80, disk_threshold: 90)

        expect(host.threshold_for("server_cpu")).to eq(70)
        expect(host.threshold_for("server_mem")).to eq(80)
        expect(host.threshold_for("server_disk")).to eq(90)
      end

      it "è nil per una metrica senza soglia impostata" do
        expect(build(:server_host, cpu_threshold: nil).threshold_for("server_cpu")).to be_nil
      end

      it "è nil per un evento senza soglia per-macchina (temp, database, down)" do
        host = build(:server_host, cpu_threshold: 70)

        expect(host.threshold_for("server_temp")).to be_nil
        expect(host.threshold_for("server_down")).to be_nil
      end
    end
  end

  describe "#database?" do
    it "è true quando lo snapshot porta l'elenco dei database" do
      host = build(:server_host, database_snapshot: { "databases" => [ { "name" => "app_production" } ] })

      expect(host.database?).to be(true)
    end

    it "è false senza snapshot o con elenco vuoto" do
      expect(build(:server_host).database?).to be(false)
      expect(build(:server_host, database_snapshot: { "databases" => [] }).database?).to be(false)
    end
  end

  # CYRA-465 — su VM senza sensori la temperatura non arriva mai: temp_max resta nil a ogni campione.
  # Il flag deriva dai campioni (tutta la retention grezza), così un bare-metal che un giorno la
  # esponesse la fa ricomparire da sé, senza cablare nulla nel codice.
  describe "#reports_temperature?" do
    it "è false per una macchina senza campioni" do
      expect(create(:server_host).reports_temperature?).to be(false)
    end

    it "è false quando ogni campione ha la temperatura vuota (nessun sensore)" do
      host = create(:server_host)
      create(:server_sample, host: host, temp_max: nil)

      expect(host.reports_temperature?).to be(false)
    end

    it "è true appena un campione porta una temperatura" do
      host = create(:server_host)
      create(:server_sample, host: host, temp_max: 48.5)

      expect(host.reports_temperature?).to be(true)
    end

    it "non guarda i campioni di un'altra macchina" do
      host = create(:server_host)
      create(:server_sample, temp_max: 50.0)

      expect(host.reports_temperature?).to be(false)
    end
  end

  # CYRA-245 — la finestra entro cui una sonda reinstallata può prendere il posto della precedente.
  # Scade da sola: un clic per sbaglio non lascia la macchina esposta per sempre.
  describe "#reenrollment_open?" do
    it "è false quando nessuno l'ha aperta" do
      expect(build(:server_host).reenrollment_open?).to be(false)
    end

    it "è true appena una persona l'ha aperta" do
      expect(build(:server_host, reenrollment_requested_at: Time.current).reenrollment_open?).to be(true)
    end

    it "è false quando la finestra è scaduta" do
      host = build(:server_host,
                   reenrollment_requested_at: (Servers::Constants::REENROLLMENT_WINDOW_SECONDS + 60).seconds.ago)

      expect(host.reenrollment_open?).to be(false)
    end
  end
end
