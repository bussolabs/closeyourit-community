# frozen_string_literal: true

require "rails_helper"

RSpec.describe Servers::ContainerSample, type: :model do
  # Due revisioni git plausibili: Kamal chiama il container `<servizio>-<ruolo>-<revisione>`.
  let(:old_release) { "7011b9d57b5f83845ea012073088b8c29b7b433a" }
  let(:new_release) { "c4d1e2f3a4b5968778695a4b3c2d1e0f9a8b7c6d" }

  describe "validazioni" do
    it "è valido con host, name e recorded_at" do
      expect(build(:server_container_sample)).to be_valid
    end

    it "richiede il name" do
      expect(build(:server_container_sample, name: "")).not_to be_valid
    end
  end

  describe ".latest_set_for" do
    let(:now) { Time.zone.local(2026, 7, 2, 12, 0, 0) }

    it "ritorna none senza campioni" do
      host = create(:server_host)

      expect(described_class.latest_set_for(host)).to be_empty
    end

    it "ritorna solo le righe dell'ultimo recorded_at, ordinate per name" do
      host = create(:server_host)
      create(:server_container_sample, host: host, name: "old", recorded_at: now - 2.minutes)
      create(:server_container_sample, host: host, name: "beta", recorded_at: now - 1.minute)
      create(:server_container_sample, host: host, name: "alfa", recorded_at: now - 1.minute)

      expect(described_class.latest_set_for(host).map(&:name)).to eq(%w[alfa beta])
    end

    it "non mescola host diversi" do
      host = create(:server_host)
      other = create(:server_host, organization: host.organization)
      create(:server_container_sample, host: other, name: "altrui", recorded_at: now)
      create(:server_container_sample, host: host, name: "mio", recorded_at: now - 5.minutes)

      expect(described_class.latest_set_for(host).map(&:name)).to eq(%w[mio])
    end
  end

  describe ".expected_names_for" do
    let(:now) { Time.zone.local(2026, 7, 2, 12, 0, 0) }
    let(:host) { create(:server_host) }

    it "elenca i nomi visti nella finestra" do
      create(:server_container_sample, host: host, name: "web", recorded_at: now - 5.minutes)
      create(:server_container_sample, host: host, name: "worker", recorded_at: now - 1.minute)

      expect(described_class.expected_names_for(host, now: now)).to contain_exactly("web", "worker")
    end

    it "dimentica chi non si vede da oltre la finestra" do
      create(:server_container_sample, host: host, name: "vecchio", recorded_at: now - 31.minutes)
      create(:server_container_sample, host: host, name: "recente", recorded_at: now - 1.minute)

      expect(described_class.expected_names_for(host, now: now)).to eq(%w[recente])
    end

    it "esclude i container gestiti da un idle-sleep manager" do
      create(:server_container_sample, host: host, name: "dorme", recorded_at: now, idle_managed: true)
      create(:server_container_sample, host: host, name: "sveglio", recorded_at: now, idle_managed: false)

      expect(described_class.expected_names_for(host, now: now)).to eq(%w[sveglio])
    end

    it "non trasforma un container già fermo in un nome atteso" do
      create(:server_container_sample, host: host, name: "stopped", recorded_at: now, running: false)
      create(:server_container_sample, host: host, name: "running", recorded_at: now, running: true)

      expect(described_class.expected_names_for(host, now: now)).to eq(%w[running])
    end

    it "esclude i nomi usa-e-getta di Kamal, che non torneranno mai" do
      create(:server_container_sample, host: host, name: "app-web_replaced_6b7441cf", recorded_at: now)
      create(:server_container_sample, host: host, name: "app-web-exec-latest-staging-cb9c24", recorded_at: now)
      create(:server_container_sample, host: host, name: "app-web", recorded_at: now)

      expect(described_class.expected_names_for(host, now: now)).to eq(%w[app-web])
    end

    # CYRA-518 — sui runner di CI ogni lavorazione accende i suoi database di servizio e li spegne
    # alla fine: il nome che GitHub Actions gli dà è riconoscibile da solo, senza che nessuno debba
    # configurare la macchina (`<32 esadecimali>_<immagine senza punteggiatura>_<6 esadecimali>`).
    it "esclude i container di servizio che le lavorazioni di CI accendono e spengono" do
      create(:server_container_sample, host: host, recorded_at: now,
             name: "4c39c1d1f4a04f0b8e5b8f5a0f3a1c7e_pgvectorpgvectorpg17_2b6a0f")
      create(:server_container_sample, host: host, recorded_at: now,
             name: "9f1e2d3c4b5a69788796a5b4c3d2e1f0_postgispostgis1634_9a1b2c")
      create(:server_container_sample, host: host, name: "db", recorded_at: now)

      expect(described_class.expected_names_for(host, now: now)).to eq(%w[db])
    end

    it "tiene atteso un servizio vero il cui nome somiglia a quelli delle lavorazioni" do
      simile = "db_pgvectorpgvectorpg17_2b6a0f"          # manca il codice di lavorazione davanti
      corto  = "4c39c1d1f4a04f0b8e5b8f5a0f3a1c7e_pgvector_2b6a0" # codice finale di 5 cifre, non 6
      suffisso = "4c39c1d1f4a04f0b8e5b8f5a0f3a1c7e_pgvector_2b6a0f-data" # continua dopo il codice
      [ simile, corto, suffisso ].each do |name|
        create(:server_container_sample, host: host, name: name, recorded_at: now)
      end

      expect(described_class.expected_names_for(host, now: now)).to contain_exactly(simile, corto, suffisso)
    end

    it "non ripete un nome campionato più volte" do
      create(:server_container_sample, host: host, name: "web", recorded_at: now - 2.minutes)
      create(:server_container_sample, host: host, name: "web", recorded_at: now - 1.minute)

      expect(described_class.expected_names_for(host, now: now)).to eq(%w[web])
    end

    it "non mescola host diversi" do
      other = create(:server_host, organization: host.organization)
      create(:server_container_sample, host: other, name: "altrui", recorded_at: now)
      create(:server_container_sample, host: host, name: "mio", recorded_at: now)

      expect(described_class.expected_names_for(host, now: now)).to eq(%w[mio])
    end

    # CYRA-774 — di una stessa identità di rilascio la versione precedente l'ha ritirata una
    # pubblicazione, non un guasto: tenerla attesa per tutta la finestra la faceva comparire
    # nell'avviso di un guasto successivo, accanto al nome che era caduto davvero.
    it "di una stessa identità di rilascio tiene atteso solo l'ultimo visto in piedi" do
      create(:server_container_sample, host: host, name: "acme-web-#{old_release}", recorded_at: now - 5.minutes)
      create(:server_container_sample, host: host, name: "acme-web-#{new_release}", recorded_at: now - 1.minute)

      expect(described_class.expected_names_for(host, now: now)).to eq([ "acme-web-#{new_release}" ])
    end

    it "durante il passaggio, con entrambe le versioni in piedi nello stesso istante, le attende tutte e due" do
      create(:server_container_sample, host: host, name: "acme-web-#{old_release}", recorded_at: now - 1.minute)
      create(:server_container_sample, host: host, name: "acme-web-#{new_release}", recorded_at: now - 1.minute)

      expect(described_class.expected_names_for(host, now: now))
        .to contain_exactly("acme-web-#{old_release}", "acme-web-#{new_release}")
    end

    it "non confonde due servizi diversi che condividono l'inizio del nome" do
      create(:server_container_sample, host: host, name: "acme-web-#{old_release}", recorded_at: now - 5.minutes)
      create(:server_container_sample, host: host, name: "acme-worker-#{new_release}", recorded_at: now - 1.minute)

      expect(described_class.expected_names_for(host, now: now))
        .to contain_exactly("acme-web-#{old_release}", "acme-worker-#{new_release}")
    end

    # La versione va riconosciuta dalla FORMA (revisione di 40 esadecimali), non da «l'ultimo pezzo
    # dopo il trattino»: `db-16` e `db-17` sono due servizi che convivono, non due versioni dello
    # stesso, e scambiarli nasconderebbe un guasto vero.
    it "non tratta come versioni di uno stesso servizio due nomi che finiscono con un numero" do
      create(:server_container_sample, host: host, name: "db-16", recorded_at: now - 5.minutes)
      create(:server_container_sample, host: host, name: "db-17", recorded_at: now - 1.minute)

      expect(described_class.expected_names_for(host, now: now)).to contain_exactly("db-16", "db-17")
    end
  end

  # CYRA-774 — le etichette Docker con servizio e ruolo non viaggiano nel push dell'agent, e nemmeno
  # lo stato di uscita: il nome che Kamal dà al container è l'unico posto dove quell'identità è già
  # scritta.
  describe ".reject_replaced_by_release" do
    it "toglie dai caduti il nome che una versione nuova dello stesso servizio ha sostituito" do
      missing = [ "acme-web-#{old_release}" ]
      running = [ "acme-web-#{new_release}", "kamal-proxy" ]

      expect(described_class.reject_replaced_by_release(missing, running)).to be_empty
    end

    it "tiene fra i caduti il nome per cui nessuna versione è ripartita" do
      missing = [ "acme-web-#{old_release}" ]

      expect(described_class.reject_replaced_by_release(missing, %w[kamal-proxy]))
        .to eq([ "acme-web-#{old_release}" ])
    end

    it "tiene fra i caduti un nome senza versione, che nessun rilascio può aver sostituito" do
      expect(described_class.reject_replaced_by_release(%w[kamal-proxy], [ "acme-web-#{new_release}" ]))
        .to eq(%w[kamal-proxy])
    end

    it "non lascia che il rilascio di un servizio copra il guasto di un altro" do
      missing = [ "acme-web-#{old_release}", "acme-worker-#{old_release}" ]
      running = [ "acme-web-#{new_release}" ]

      expect(described_class.reject_replaced_by_release(missing, running))
        .to eq([ "acme-worker-#{old_release}" ])
    end

    it "riconosce anche la versione pubblicata da un albero di lavoro sporco" do
      missing = [ "acme-web-#{old_release}_uncommitted_0123456789abcdef" ]
      running = [ "acme-web-#{new_release}" ]

      expect(described_class.reject_replaced_by_release(missing, running)).to be_empty
    end
  end

  describe ".buckets_for" do
    let(:now) { Time.zone.local(2026, 7, 2, 12, 0, 0) }

    it "aggrega la serie del singolo container per nome" do
      host = create(:server_host)
      create(:server_container_sample, host: host, name: "web", recorded_at: now - 1.minute,
             cpu_pct: 10.0, mem_bytes: 100)
      create(:server_container_sample, host: host, name: "web", recorded_at: now - 70.seconds,
             cpu_pct: 20.0, mem_bytes: 300)
      create(:server_container_sample, host: host, name: "altro", recorded_at: now - 1.minute, cpu_pct: 99.0)

      buckets = described_class.buckets_for(host, "web", "30m", now)

      expect(buckets.length).to eq(30)
      expect(buckets.last[:count]).to eq(1)
      expect(buckets.last[:cpu]).to eq(10.0)
      expect(buckets[-2][:count]).to eq(1)
      expect(buckets[-2][:mem_bytes]).to eq(300)
      expect(buckets.first).to eq(count: 0, cpu: nil, mem_bytes: nil)
    end

    it "un now con i nanosecondi non sposta i blocchi di uno: l'ultimo resta quello corrente" do
      host = create(:server_host)
      ns_now = Time.utc(2026, 7, 2, 12, 0, Rational(1_234_567_891, 1_000_000_000))
      create(:server_container_sample, host: host, name: "web", recorded_at: ns_now - 30.seconds, cpu_pct: 10.0)

      buckets = described_class.buckets_for(host, "web", "30m", ns_now)

      expect(buckets.last).to include(count: 1, cpu: 10.0)
      expect(buckets[-2][:count]).to eq(0)
    end
  end

  describe "enum health" do
    it "espone i valori del vocabolario Docker" do
      expect(described_class.healths.keys).to eq(%w[none starting healthy unhealthy])
    end
  end
end
