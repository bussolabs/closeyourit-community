# frozen_string_literal: true

require "rails_helper"

# Snapshot title/body/url degli eventi server_* (subject = Servers::Host, project nil).
RSpec.describe Alerting::Content do
  let(:host) do
    create(:server_host, name: "apps", hostname: "apps.internal", cpu_pct: 95.5, mem_pct: 91.0,
           disk_pct: 88.2, temp_max: 84.0, failed_services: %w[backup.service],
           smart_data: { "nvme0" => { "status" => "FAILED" }, "sda" => { "status" => "PASSED" } })
  end

  it "server_down: titolo con host, url alla pagina server, project nil" do
    content = described_class.for(event_type: "server_down", subject: host)

    expect(content.title).to include("apps")
    expect(content.body).to include("apps.internal")
    expect(content.url).to eq("/member/monitoring/servers/#{host.id}")
    expect(content.project).to be_nil
  end

  it "server_up: titolo di ripristino" do
    content = described_class.for(event_type: "server_up", subject: host)

    expect(content.title).to include("apps")
    expect(content.project).to be_nil
  end

  it "eventi soglia: il body porta il valore dello snapshot host" do
    expect(described_class.for(event_type: "server_cpu", subject: host).body).to include("95.5")
    expect(described_class.for(event_type: "server_mem", subject: host).body).to include("91.0")
    expect(described_class.for(event_type: "server_disk", subject: host).body).to include("88.2")
    expect(described_class.for(event_type: "server_temp", subject: host).body).to include("84.0")
  end

  # CYRA-678: il body NOMINA le unit cadute — chi legge alle tre di notte non deve aprire il pannello
  # per sapere cos'è caduto. Rovescia la regola di CYRA-323 («conteggio+host, l'elenco in details»),
  # che resta valida per gli altri avvisi di questo file: `details` continua a portare l'elenco
  # completo, il body si ferma ai primi cinque nomi.
  it "server_service_failed: body con conteggio, host e nomi delle unit" do
    content = described_class.for(event_type: "server_service_failed", subject: host)

    expect(content.body).to eq("1 service failing on apps: backup.service.")
    expect(content.details).to eq(%w[backup.service])
  end

  it "server_service_failed: plurale con più servizi failed" do
    host.update!(failed_services: %w[backup.service nginx.service])
    content = described_class.for(event_type: "server_service_failed", subject: host)

    expect(content.body).to eq("2 services failing on apps: backup.service, nginx.service.")
    expect(content.details).to eq(%w[backup.service nginx.service])
  end

  it "server_smart_failing: body con conteggio+host, l'elenco dei soli device non-PASSED va in details" do
    content = described_class.for(event_type: "server_smart_failing", subject: host)

    expect(content.body).to eq("1 disk failing on apps.")
    expect(content.details).to eq(%w[nvme0])
  end

  # CYRA-248: un container morto sparisce dal push. Il body riporta conteggio+host; l'elenco dei nomi
  # caduti resta consultabile in details. Se sono spariti tutti insieme, un unico avviso dice che il
  # motore non risponde (nessun conteggio, nessun details).
  describe "server_container_down" do
    it "body con conteggio+host (motore su), url server, project nil, elenco in details" do
      host.update!(container_outage: { "names" => %w[redis memcached] })
      content = described_class.for(event_type: "server_container_down", subject: host)

      expect(content.title).to include("apps")
      expect(content.body).to eq("2 containers down on apps.")
      expect(content.details).to eq(%w[redis memcached])
      expect(content.url).to eq("/member/monitoring/servers/#{host.id}")
      expect(content.project).to be_nil
    end

    it "singolare con un solo container caduto" do
      host.update!(container_outage: { "names" => %w[redis] })
      content = described_class.for(event_type: "server_container_down", subject: host)

      expect(content.body).to eq("1 container down on apps.")
    end

    it "motore giù (tutti spariti insieme): body col motore che non risponde, nessun details" do
      host.update!(container_outage: { "engine_down" => true })
      content = described_class.for(event_type: "server_container_down", subject: host)

      expect(content.title).to include("apps")
      expect(content.body).to include("apps.internal")
      expect(content.project).to be_nil
      expect(content.details).to be_nil
    end
  end

  it "host senza hostname usa il name nel body down/up" do
    host.update!(hostname: nil)

    expect(described_class.for(event_type: "server_down", subject: host).body).to include("apps")
  end

  # CYRA-181: eventi del database rilevato sull'host — stesso subject/url/project degli altri server_*.
  describe "eventi database" do
    before do
      host.update!(database_snapshot: {
        "engine" => "postgresql", "reachable" => false, "role" => "primary",
        "connections" => { "total" => 90, "max" => 100, "reserved" => 5 },
        "replication" => { "streaming" => false, "lag_seconds" => 42.5 }
      })
    end

    it "server_db_down: titolo con host, body con hostname, url alla pagina server, project nil" do
      content = described_class.for(event_type: "server_db_down", subject: host)

      expect(content.title).to include("apps")
      expect(content.body).to include("apps.internal")
      expect(content.url).to eq("/member/monitoring/servers/#{host.id}")
      expect(content.project).to be_nil
    end

    it "server_db_connections: body con connessioni aperte su massimo" do
      content = described_class.for(event_type: "server_db_connections", subject: host)

      expect(content.title).to include("apps")
      expect(content.body).to include("90").and include("100")
      expect(content.project).to be_nil
    end


    it "server_db_connection_usage: body con slot realmente disponibili e percentuale" do
      content = described_class.for(event_type: "server_db_connection_usage", subject: host)

      expect(content.body).to include("90").and include("95").and include("94.7")
    end

    it "server_replication_down/up: distingue caduta e recupero" do
      host.update!(replication_outage: { "role" => "primary", "expected" => 1, "streaming" => 0 })

      expect(described_class.for(event_type: "server_replication_down", subject: host).body)
        .to include("0").and include("1")
      expect(described_class.for(event_type: "server_replication_up", subject: host).body).to be_present
    end

    it "server_replication_lag: body col lag in secondi" do
      content = described_class.for(event_type: "server_replication_lag", subject: host)

      expect(content.title).to include("apps")
      expect(content.body).to include("42.5")
      expect(content.project).to be_nil
    end

    it "snapshot senza sotto-oggetti (DB non sondabile) non solleva" do
      host.update!(database_snapshot: { "engine" => "postgresql", "reachable" => false })

      expect(described_class.for(event_type: "server_db_connections", subject: host).body).to be_present
      expect(described_class.for(event_type: "server_replication_lag", subject: host).body).to be_present
    end
  end


  it "eventi volume/inode identificano il mount responsabile" do
    host.update!(resource_pressure: {
      "data_volume_disk" => { "name" => "pgdata", "mountpoint" => "/mnt/pgdata", "pct" => 91.2 },
      "inode" => { "name" => "root", "mountpoint" => "/", "pct" => 88.0 }
    })

    disk = described_class.for(event_type: "server_data_volume_disk", subject: host)
    inode = described_class.for(event_type: "server_inode", subject: host)
    expect(disk.body).to include("/mnt/pgdata").and include("91.2")
    expect(disk.details).to eq(%w[pgdata])
    expect(inode.body).to include("/").and include("88.0")
  end

  it "restart loop espone il container responsabile e il rientro" do
    host.update!(container_restart_outage: {
      "containers" => [ { "name" => "worker", "restarts" => 4, "oom_killed" => false } ]
    })

    loop_content = described_class.for(event_type: "server_container_restart_loop", subject: host)
    expect(loop_content.body).to include("1 container")
    expect(loop_content.details).to include(include("worker", "4"))
    expect(described_class.for(event_type: "server_container_stable", subject: host).body).to be_present
  end
end
