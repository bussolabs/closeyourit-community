# frozen_string_literal: true

require "rails_helper"

RSpec.describe Servers::Sample, type: :model do
  describe "validazioni" do
    it "è valido con host, recorded_at e cpu_pct" do
      expect(build(:server_sample)).to be_valid
    end

    it "richiede recorded_at" do
      expect(build(:server_sample, recorded_at: nil)).not_to be_valid
    end

    it "rifiuta a livello DB un duplicato [host, recorded_at] (idempotenza retry)" do
      existing = create(:server_sample)

      expect {
        create(:server_sample, host: existing.host, recorded_at: existing.recorded_at)
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe ".range_duration / .bucket_config" do
    it "risolve una chiave nota" do
      expect(described_class.range_duration("7d")).to eq(7.days)
      expect(described_class.bucket_config("30m")[:count]).to eq(30)
    end

    it "cade sul default per chiave ignota" do
      expect(described_class.range_duration("boom")).to eq(24.hours)
      expect(described_class.bucket_config("boom")).to eq(described_class::BUCKETS["24h"])
    end
  end

  describe ".database_size_buckets" do
    let(:now) { Time.zone.local(2026, 7, 2, 12, 0, 0) }
    let(:host) { create(:server_host) }

    def sample_with(databases, at:)
      create(:server_sample, host: host, recorded_at: at,
             payload: { "database" => { "databases" => databases } })
    end

    it "riporta la dimensione del database per blocco, e nil dove non ci sono campioni" do
      sample_with([ { "name" => "app_production", "size_bytes" => 800 },
                    { "name" => "altro", "size_bytes" => 5 } ], at: now - 2.minutes)
      # Nello stesso blocco arriva un campione più grande: si tiene il massimo (la dimensione cresce).
      sample_with([ { "name" => "app_production", "size_bytes" => 830 } ], at: now - 1.minute)

      buckets = described_class.database_size_buckets(host_id: host.id, name: "app_production",
                                                      range: "30m", now: now)

      expect(buckets.length).to eq(30)
      expect(buckets.last[:size_bytes]).to eq(830)
      expect(buckets.last[:at]).to eq(now - 1.minute)
      # Blocchi da 1 minuto: il campione di due minuti fa sta nel penultimo.
      expect(buckets[-2][:size_bytes]).to eq(800)
      expect(buckets.first[:size_bytes]).to be_nil
    end

    it "un now con i nanosecondi non sposta i blocchi di uno: l'ultimo resta quello corrente" do
      ns_now = Time.utc(2026, 7, 2, 12, 0, Rational(1_234_567_891, 1_000_000_000))
      sample_with([ { "name" => "app_production", "size_bytes" => 830 } ], at: ns_now - 30.seconds)

      buckets = described_class.database_size_buckets(host_id: host.id, name: "app_production",
                                                      range: "30m", now: ns_now)

      expect(buckets.last[:size_bytes]).to eq(830)
      expect(buckets[-2][:size_bytes]).to be_nil
    end

    it "ignora i campioni fuori dalla finestra" do
      sample_with([ { "name" => "app_production", "size_bytes" => 800 } ], at: now - 2.hours)

      buckets = described_class.database_size_buckets(host_id: host.id, name: "app_production",
                                                      range: "30m", now: now)

      expect(buckets.map { |b| b[:size_bytes] }.compact).to be_empty
    end

    it "ritorna blocchi vuoti per un database che non esiste in quei campioni" do
      sample_with([ { "name" => "app_production", "size_bytes" => 800 } ], at: now - 1.minute)

      buckets = described_class.database_size_buckets(host_id: host.id, name: "mai_visto",
                                                      range: "30m", now: now)

      expect(buckets.map { |b| b[:size_bytes] }.compact).to be_empty
    end

    it "tratta come dato un nome con apici e virgolette (mai interpolato nella query)" do
      cattivo = %q(strano'" ? (@.name == "app_production") name)
      sample_with([ { "name" => cattivo, "size_bytes" => 42 },
                    { "name" => "app_production", "size_bytes" => 800 } ], at: now - 1.minute)

      buckets = described_class.database_size_buckets(host_id: host.id, name: cattivo,
                                                      range: "30m", now: now)

      expect(buckets.last[:size_bytes]).to eq(42)
    end

    it "ignora i campioni di un altro host" do
      altro = create(:server_host, organization: host.organization)
      create(:server_sample, host: altro, recorded_at: now - 1.minute,
             payload: { "database" => { "databases" => [ { "name" => "app_production", "size_bytes" => 999 } ] } })

      buckets = described_class.database_size_buckets(host_id: host.id, name: "app_production",
                                                      range: "30m", now: now)

      expect(buckets.map { |b| b[:size_bytes] }.compact).to be_empty
    end
  end

  describe ".buckets_for" do
    it "un now con i nanosecondi non sposta i blocchi di uno: l'ultimo resta quello corrente" do
      host = create(:server_host)
      now = Time.utc(2026, 7, 2, 12, 0, Rational(1_234_567_891, 1_000_000_000))
      create(:server_sample, host: host, recorded_at: now - 30.seconds, cpu_pct: 42.0)

      buckets = described_class.buckets_for([ host.id ], "30m", now)[host.id]

      expect(buckets.last).to include(count: 1, cpu: 42.0)
      expect(buckets[-2][:count]).to eq(0)
    end
  end

  describe ".database_size_changes" do
    let(:now) { Time.zone.local(2026, 7, 2, 12, 0, 0) }
    let(:host) { create(:server_host) }

    def sample_with(databases, at:, on: host)
      create(:server_sample, host: on, recorded_at: at,
             payload: { "database" => { "databases" => databases } })
    end

    it "delta dal primo all'ultimo campione nella finestra, per (host, database)" do
      sample_with([ { "name" => "app_production", "size_bytes" => 700 } ], at: now - 6.days)
      sample_with([ { "name" => "app_production", "size_bytes" => 830 } ], at: now - 2.days)
      sample_with([ { "name" => "app_production", "size_bytes" => 1000 } ], at: now - 1.hour)

      changes = described_class.database_size_changes(host_ids: [ host.id ], range: "7d", now: now)

      expect(changes[[ host.id, "app_production" ]]).to eq(300)
    end

    it "un delta per ciascun database dello stesso host" do
      sample_with([ { "name" => "a", "size_bytes" => 100 }, { "name" => "b", "size_bytes" => 50 } ], at: now - 5.days)
      sample_with([ { "name" => "a", "size_bytes" => 160 }, { "name" => "b", "size_bytes" => 40 } ], at: now - 1.hour)

      changes = described_class.database_size_changes(host_ids: [ host.id ], range: "7d", now: now)

      expect(changes[[ host.id, "a" ]]).to eq(60)
      # Un database può anche calare (VACUUM FULL, drop di tabelle): il delta è negativo, non zero.
      expect(changes[[ host.id, "b" ]]).to eq(-10)
    end

    it "calcola più host in un colpo, senza confonderli" do
      altro = create(:server_host, organization: host.organization)
      sample_with([ { "name" => "app_production", "size_bytes" => 100 } ], at: now - 5.days)
      sample_with([ { "name" => "app_production", "size_bytes" => 250 } ], at: now - 1.hour)
      sample_with([ { "name" => "app_production", "size_bytes" => 900 } ], at: now - 5.days, on: altro)
      sample_with([ { "name" => "app_production", "size_bytes" => 950 } ], at: now - 1.hour, on: altro)

      changes = described_class.database_size_changes(host_ids: [ host.id, altro.id ], range: "7d", now: now)

      expect(changes[[ host.id, "app_production" ]]).to eq(150)
      expect(changes[[ altro.id, "app_production" ]]).to eq(50)
    end

    it "database più giovane della finestra (assente al primo campione) → nessun delta, non uno zero" do
      # Al primo bordo esiste solo app_production; nuovo_db compare dopo: non c'è un valore di partenza.
      sample_with([ { "name" => "app_production", "size_bytes" => 100 } ], at: now - 5.days)
      sample_with([ { "name" => "app_production", "size_bytes" => 120 },
                    { "name" => "nuovo_db", "size_bytes" => 500 } ], at: now - 1.hour)

      changes = described_class.database_size_changes(host_ids: [ host.id ], range: "7d", now: now)

      expect(changes).to have_key([ host.id, "app_production" ])
      expect(changes).not_to have_key([ host.id, "nuovo_db" ])
    end

    it "host con un solo campione → nessun delta (niente storia da dichiarare)" do
      sample_with([ { "name" => "app_production", "size_bytes" => 100 } ], at: now - 1.hour)

      expect(described_class.database_size_changes(host_ids: [ host.id ], range: "7d", now: now)).to eq({})
    end

    it "ignora i campioni fuori dalla finestra" do
      sample_with([ { "name" => "app_production", "size_bytes" => 100 } ], at: now - 40.days)
      sample_with([ { "name" => "app_production", "size_bytes" => 300 } ], at: now - 1.hour)

      # Con un solo campione DENTRO i 7 giorni non c'è delta: il vecchissimo non conta come partenza.
      expect(described_class.database_size_changes(host_ids: [ host.id ], range: "7d", now: now)).to eq({})
    end

    it "senza host → hash vuoto, nessuna query inutile" do
      expect(described_class.database_size_changes(host_ids: [], range: "7d", now: now)).to eq({})
    end
  end

  describe ".default_range_for" do
    let(:now) { Time.zone.local(2026, 7, 2, 12, 0, 0) }
    let(:host) { create(:server_host) }

    it "senza host → il default onesto (24h)" do
      expect(described_class.default_range_for([], now)).to eq("24h")
    end

    it "host senza campioni → 24h (il vuoto è legittimo, lo dichiara la traccia tratteggiata)" do
      expect(described_class.default_range_for(host.id, now)).to eq("24h")
    end

    it "host arrivato da poco (storia < 30m) → la finestra più corta (30m), non 24h quasi vuota" do
      create(:server_sample, host: host, recorded_at: now - 10.minutes)

      expect(described_class.default_range_for(host.id, now)).to eq("30m")
    end

    it "storia di ~90 minuti → 30m (la sola finestra interamente coperta)" do
      create(:server_sample, host: host, recorded_at: now - 90.minutes)
      create(:server_sample, host: host, recorded_at: now - 1.minute)

      expect(described_class.default_range_for(host.id, now)).to eq("30m")
    end

    it "storia di ~3 giorni → 24h (la più lunga coperta per intero)" do
      create(:server_sample, host: host, recorded_at: now - 3.days)
      create(:server_sample, host: host, recorded_at: now - 1.minute)

      expect(described_class.default_range_for(host.id, now)).to eq("24h")
    end

    it "storia di ~10 giorni → 7d" do
      create(:server_sample, host: host, recorded_at: now - 10.days)
      create(:server_sample, host: host, recorded_at: now - 1.minute)

      expect(described_class.default_range_for(host.id, now)).to eq("7d")
    end

    it "ignora i campioni oltre la finestra massima (30d) nel calcolo dello span" do
      create(:server_sample, host: host, recorded_at: now - 40.days)

      expect(described_class.default_range_for(host.id, now)).to eq("24h")
    end

    it "host muto con dati vecchi → una finestra che INCLUDE gli ultimi campioni, non un range breve vuoto" do
      # Storia da 20 a 15 giorni fa, poi silenzio: 7d ([now-7d, now]) cadrebbe tutta DOPO l'ultimo
      # campione e si aprirebbe vuota. La finestra scelta deve arrivare fino ai dati.
      create(:server_sample, host: host, recorded_at: now - 20.days)
      create(:server_sample, host: host, recorded_at: now - 15.days)

      expect(described_class.default_range_for(host.id, now)).to eq("30d")
    end
  end

  describe ".buckets_for" do
    let(:now) { Time.zone.local(2026, 7, 2, 12, 0, 0) }

    it "ritorna {} senza host" do
      expect(described_class.buckets_for([], "24h", now)).to eq({})
    end

    it "aggrega i campioni nel bucket giusto (media cpu/mem, max temp, somma net)" do
      host = create(:server_host)
      # range 30m → 30 bucket da 1 minuto, finestra [now - 30m, now). Ultimo bucket = [now-1m, now).
      create(:server_sample, host: host, recorded_at: now - 1.minute, cpu_pct: 10.0, mem_pct: 20.0,
             temp_max: 40.0, net_sent_bytes: 100, net_recv_bytes: 10)
      create(:server_sample, host: host, recorded_at: now - 30.seconds, cpu_pct: 30.0, mem_pct: 40.0,
             temp_max: 60.0, net_sent_bytes: 200, net_recv_bytes: 20)

      buckets = described_class.buckets_for(host.id, "30m", now)[host.id]

      expect(buckets.length).to eq(30)
      last = buckets.last
      expect(last[:count]).to eq(2)
      expect(last[:cpu]).to eq(20.0)
      expect(last[:mem]).to eq(30.0)
      expect(last[:temp]).to eq(60.0)
      expect(last[:net_out]).to eq(300)
      expect(last[:net_in]).to eq(30)
      # `at` = istante d'inizio del blocco (asse X / finestra oraria del tooltip in vista). Ultimo
      # bucket di 30m (30×1min) = [now - 1m, now) → inizia a now - 1.minute.
      expect(last[:at]).to eq(now - 1.minute)
      expect(buckets.first[:at]).to eq(now - 30.minutes)
    end

    it "lascia vuoti i bucket senza campioni e separa gli host" do
      host_a = create(:server_host)
      host_b = create(:server_host, organization: host_a.organization)
      create(:server_sample, host: host_a, recorded_at: now - 1.minute, cpu_pct: 50.0)

      buckets = described_class.buckets_for([ host_a.id, host_b.id ], "30m", now)

      expect(buckets[host_a.id].last[:count]).to eq(1)
      expect(buckets[host_a.id].first).to eq(count: 0, at: now - 30.minutes, cpu: nil, mem: nil, disk: nil,
                                             temp: nil, mem_gb: nil, disk_gb: nil, net_out: nil, net_in: nil,
                                             gpu: nil, gpu_watt: nil, cpu_user: nil, cpu_system: nil,
                                             cpu_iowait: nil, cpu_steal: nil,
                                             db_conn: nil, db_conn_max: nil, db_lag: nil)
      expect(buckets[host_b.id]).to all(include(count: 0))
    end

    it "aggrega le metriche database (media e picco connessioni, max lag di replica)" do
      host = create(:server_host)
      create(:server_sample, host: host, recorded_at: now - 1.minute,
             db_up: true, db_connections: 10, db_replication_lag_seconds: 0.5)
      create(:server_sample, host: host, recorded_at: now - 30.seconds,
             db_up: true, db_connections: 30, db_replication_lag_seconds: 1.25)

      last = described_class.buckets_for(host.id, "30m", now)[host.id].last

      expect(last[:db_conn]).to eq(20.0)
      expect(last[:db_conn_max]).to eq(30)
      expect(last[:db_lag]).to eq(1.25)
    end

    it "host senza database: le metriche db restano nil (colonne NULL)" do
      host = create(:server_host)
      create(:server_sample, host: host, recorded_at: now - 1.minute, cpu_pct: 10.0)

      last = described_class.buckets_for(host.id, "30m", now)[host.id].last

      expect(last[:count]).to eq(1)
      expect(last[:db_conn]).to be_nil
      expect(last[:db_conn_max]).to be_nil
      expect(last[:db_lag]).to be_nil
    end

    it "esclude i campioni fuori finestra (prima di since e >= now)" do
      host = create(:server_host)
      create(:server_sample, host: host, recorded_at: now - 31.minutes, cpu_pct: 99.0)
      create(:server_sample, host: host, recorded_at: now, cpu_pct: 99.0)

      buckets = described_class.buckets_for(host.id, "30m", now)[host.id]

      expect(buckets).to all(include(count: 0))
    end

    # CYRA-472: i GB occupati vengono dal payload del campione, non dalla percentuale. Ricavarli da
    # pct × totale attuale darebbe numeri sbagliati su tutta la storia dopo un resize di RAM o disco.
    describe "GB occupati (mem_gb / disk_gb)" do
      it "aggrega la misura del campione, indipendente dal taglio attuale della macchina" do
        host = create(:server_host, memory_total_bytes: 32 * 1_073_741_824)
        create(:server_sample, host: host, recorded_at: now - 90.seconds, mem_pct: 50.0,
               payload: { "mem" => { "total_gb" => 16.0, "used_gb" => 8.0 } })
        create(:server_sample, host: host, recorded_at: now - 30.seconds, mem_pct: 50.0,
               payload: { "mem" => { "total_gb" => 32.0, "used_gb" => 16.0 } })

        measured = described_class.buckets_for(host.id, "30m", now)[host.id].filter_map { |b| b[:mem_gb] }

        # Stessa percentuale, due tagli di RAM: restano gli 8 GB veri di allora, non 16.
        expect(measured).to eq([ 8.0, 16.0 ])
      end

      it "aggrega anche il disco" do
        host = create(:server_host)
        create(:server_sample, host: host, recorded_at: now - 30.seconds, disk_pct: 50.0,
               payload: { "disk" => { "total_gb" => 42.0, "used_gb" => 21.0 } })

        expect(described_class.buckets_for(host.id, "30m", now)[host.id].last[:disk_gb]).to eq(21.0)
      end

      it "un agent che manda used_gb come stringa non fa esplodere la query" do
        host = create(:server_host)
        create(:server_sample, host: host, recorded_at: now - 30.seconds, mem_pct: 50.0,
               payload: { "mem" => { "used_gb" => "abc" } })

        last = nil
        expect { last = described_class.buckets_for(host.id, "30m", now)[host.id].last }.not_to raise_error
        expect(last[:mem_gb]).to be_nil
        expect(last[:mem]).to eq(50.0)
      end

      it "payload senza dettaglio: nil, e la percentuale resta comunque aggregata" do
        host = create(:server_host)
        create(:server_sample, host: host, recorded_at: now - 30.seconds, mem_pct: 50.0, payload: {})

        last = described_class.buckets_for(host.id, "30m", now)[host.id].last

        expect(last[:mem_gb]).to be_nil
        expect(last[:disk_gb]).to be_nil
        expect(last[:mem]).to eq(50.0)
      end
    end
  end

  # CYRA-465 — regola la colonna dell'elenco, la sua chiave di ordinamento e l'evento di avviso della
  # temperatura: senza un solo sensore in tutta la flotta sono spazio e scelte per un dato che non
  # arriverà. Org-level: basta una macchina che la riporti perché la colonna abbia senso.
  describe ".temperature_reported?" do
    let(:organization) { create(:organization) }

    it "è false senza alcun campione" do
      expect(described_class.temperature_reported?(organization)).to be(false)
    end

    it "è false quando nessun campione dell'organizzazione porta la temperatura" do
      host = create(:server_host, organization: organization)
      create(:server_sample, host: host, temp_max: nil)

      expect(described_class.temperature_reported?(organization)).to be(false)
    end

    it "è true appena una macchina dell'organizzazione riporta la temperatura" do
      host = create(:server_host, organization: organization)
      create(:server_sample, host: host, temp_max: 48.5)

      expect(described_class.temperature_reported?(organization)).to be(true)
    end

    it "non considera i campioni di un'altra organizzazione" do
      create(:server_sample, temp_max: 60.0)

      expect(described_class.temperature_reported?(organization)).to be(false)
    end
  end

  describe ".buckets_for — i dati nuovi della scheda (CYRA-703)" do
    let(:host) { create(:server_host) }
    let(:adesso) { Time.current }

    it "media l'uso della scheda grafica e i watt nel blocco" do
      create(:server_sample, host: host, recorded_at: adesso - 2.minutes, gpu_pct: 20.0, gpu_watt: 100.0)
      create(:server_sample, host: host, recorded_at: adesso - 1.minute, gpu_pct: 40.0, gpu_watt: 140.0)

      blocchi = described_class.buckets_for([ host.id ], "30m", adesso)[host.id]
      pieni = blocchi.select { |b| b[:gpu] }

      expect(pieni.map { |b| b[:gpu] }).to contain_exactly(20.0, 40.0)
      expect(pieni.map { |b| b[:gpu_watt] }).to contain_exactly(100.0, 140.0)
    end

    it "estrae la ripartizione della CPU dal dettaglio del campione" do
      create(:server_sample, host: host, recorded_at: adesso - 1.minute,
             payload: { "cpu_breakdown" => [ 12.15, 2.33, 0.03, 0.0, 85.41 ] })

      blocco = described_class.buckets_for([ host.id ], "30m", adesso)[host.id].find { |b| b[:cpu_user] }

      expect(blocco[:cpu_user]).to eq(12.2)
      expect(blocco[:cpu_system]).to eq(2.3)
      expect(blocco[:cpu_iowait]).to eq(0.0)
      expect(blocco[:cpu_steal]).to eq(0.0)
    end

    it "lascia vuote le chiavi nuove sui campioni che non portano quei dati" do
      create(:server_sample, host: host, recorded_at: adesso - 1.minute, gpu_pct: nil, payload: {})

      blocco = described_class.buckets_for([ host.id ], "30m", adesso)[host.id].find { |b| b[:count].positive? }

      expect(blocco[:gpu]).to be_nil
      expect(blocco[:cpu_user]).to be_nil
    end
  end
end
