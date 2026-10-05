# frozen_string_literal: true

# Development only. Builds agent payloads (same wire format as closeyourit-agent, see
# spec/fixtures/servers/agent_payload.json) for a small fake fleet. Shared by db/seeds/demo_data.rb
# (24h of history) and bin/demo-agent (live pushes), so both describe the same machines.
module DemoAgent
  class FakeServer
    GB = 1024**3

    # Faults come and go so alerts fire and clear while the agent runs: [every, lasts] in minutes
    # (CYRA-932). The same clock drives the seeded history, so the charts show the past ones too.
    FLEET = [
      { name: "web-01", groups: %w[production], cpu: 35, mem: 55, disk: 48, containers: %w[storefront-web kamal-proxy],
        faults: { smart_failing: [ 30, 2 ] } },
      { name: "web-02", groups: %w[production], cpu: 30, mem: 52, disk: 46, containers: %w[storefront-web kamal-proxy] },
      { name: "api-01", groups: %w[production], cpu: 45, mem: 63, disk: 51,
        containers: %w[payments-api payments-worker kamal-proxy], faults: { container_down: [ 12, 3, "payments-worker" ] } },
      { name: "db-01", groups: %w[production database], cpu: 25, mem: 78, disk: 71, containers: [], database: true,
        faults: { db_busy: [ 15, 2 ] } },
      { name: "worker-01", groups: %w[production], cpu: 60, mem: 70, disk: 38, containers: %w[dashboard-worker],
        faults: { failed_unit: [ 10, 4, "backup.service" ] } },
      { name: "staging-01", groups: %w[staging], cpu: 12, mem: 40, disk: 88,
        containers: %w[storefront-staging payments-staging] }
    ].freeze

    JOURNAL_LINES = [
      [ 3, "backup", "Backup job failed: connection refused" ],
      [ 3, "sshd", "error: kex_exchange_identification: Connection closed by remote host" ],
      [ 3, "dockerd", "Container health check exceeded timeout" ],
      [ 2, "kernel", "Out of memory: Killed process 4321 (ruby)" ],
      [ 3, "systemd", "Failed to start Daily apt upgrade and clean activities." ],
      [ 3, "postgres", "FATAL: remaining connection slots are reserved for non-replication superuser connections" ]
    ].freeze

    def self.fleet = FLEET.map { |spec| new(**spec) }

    attr_reader :name, :groups

    def initialize(name:, groups:, cpu:, mem:, disk:, containers:, database: false, faults: {})
      @name = name
      @groups = groups
      @cpu = cpu
      @mem = mem
      @disk = disk
      @containers = containers
      @database = database
      @faults = faults
    end

    def fingerprint = "demo-#{name}"

    # One push. `journal: false` for history rows, where log lines would only pile up.
    def payload(at: Time.current, journal: true)
      @at = at
      wave = Math.sin(at.to_i / 3600.0 * Math::PI / 6) # a slow daily-ish swing
      cpu = clamp(@cpu + (wave * 15) + rand(-6.0..6.0))
      mem = clamp(@mem + (wave * 5) + rand(-2.0..2.0))
      disk = clamp(@disk + ((at.to_i % 86_400) / 86_400.0) + rand(-0.2..0.2))
      {
        "fingerprint" => fingerprint,
        "agent_version" => "0.9.0",
        "recorded_at" => at.utc.iso8601,
        "host" => host_info,
        "data" => { "stats" => stats(cpu, mem, disk), "info" => info(cpu, mem, disk),
                    "container" => containers, "systemd" => systemd },
        "smart" => { "nvme0" => { "mn" => "SAMSUNG MZVL2512HCJQ", "sn" => "DEMO#{name.upcase}", "c" => 512 * GB,
                                  "s" => fault?(:smart_failing) ? "FAILED" : "PASSED", "dn" => "/dev/nvme0", "dt" => "nvme", "t" => rand(38..46) } },
        "database" => (database_block if @database),
        "journal" => (journal_block(at) if journal)
      }.compact
    end

    private

    def clamp(value) = value.clamp(1.0, 99.0).round(2)

    # On for the first `lasts` minutes of every `every`, on the clock of the push being built.
    def fault?(kind)
      every, lasts = @faults[kind]
      every && (@at.to_i / 60) % every < lasts
    end

    def failed_unit = (@faults.dig(:failed_unit, 2) if fault?(:failed_unit))

    def host_info
      { "hostname" => name, "kernel" => "6.8.0-59-generic", "cores" => 4, "threads" => 8,
        "cpu_model" => "AMD EPYC 9454P 48-Core Processor", "os_name" => "Ubuntu 24.04.2 LTS", "arch" => "amd64",
        "memory_total" => 16 * GB, "reboot_required" => name == "worker-01", "updates_available" => 7,
        "security_updates_available" => 2 }
    end

    def stats(cpu, mem, disk)
      idle = 100 - cpu
      { "cpu" => cpu, "m" => 16.0, "mu" => (16 * mem / 100).round(2), "mp" => mem, "mb" => 1.5,
        "s" => 4.0, "su" => 0.2, "d" => 160.0, "du" => (160 * disk / 100).round(2), "dp" => disk,
        "t" => { "k10temp_tctl" => (40 + (cpu / 3)).round(1) },
        "la" => [ (cpu / 25).round(2), (cpu / 28).round(2), (cpu / 30).round(2) ],
        "b" => [ rand(50_000..900_000), rand(80_000..2_000_000) ], "dio" => [ rand(0..4_000_000), rand(0..8_000_000) ],
        "cpub" => [ (cpu * 0.7).round(1), (cpu * 0.2).round(1), (cpu * 0.08).round(1), (cpu * 0.02).round(1), idle.round(1) ],
        "proc" => [ { "p" => 812, "n" => @database ? "postgres" : "puma", "c" => (cpu / 2).round(1), "m" => 800_000_000 },
                    { "p" => 1, "n" => "systemd", "c" => 0.1, "m" => 12_000_000 } ] }
    end

    def info(cpu, mem, disk)
      { "t" => 8, "u" => 864_000, "cpu" => cpu, "mp" => mem, "dp" => disk, "v" => "0.9.0",
        "sv" => [ 42, failed_unit ? 1 : 0 ] }
    end

    def containers
      down = @faults.dig(:container_down, 2) if fault?(:container_down)
      @containers.map do |container|
        running = container != down
        { "id" => Digest::SHA256.hexdigest("#{name}-#{container}")[0, 12], "n" => container, "c" => rand(0.5..20.0).round(2),
          "m" => rand(64.0..900.0).round(2), "b" => [ rand(1_000..90_000), rand(1_000..90_000) ], "h" => 2, "st" => running ? "running" : "exited",
          "img" => "registry.example.com/#{container}:latest", "run" => running, "rc" => 0 }
      end
    end

    def systemd
      units = [ { "n" => "ssh.service", "s" => 0, "c" => 0.1, "m" => 10_485_760, "ss" => 1 } ]
      units << { "n" => failed_unit, "s" => 2, "c" => 0.0, "m" => 0, "ss" => 3 } if failed_unit
      units
    end

    def database_block
      # Usable slots are 95: busy spells cross the 80% alert, ordinary ones stay under it.
      total = fault?(:db_busy) ? rand(85..92) : rand(30..70)
      { "engine" => "postgresql", "reachable" => true, "version" => "17.2", "role" => "primary",
        "connections" => { "total" => total, "max" => 100, "reserved" => 5,
                           "by_state" => { "active" => total / 6, "idle" => total - (total / 6) } },
        "replication" => { "streaming" => true, "lag_seconds" => rand(0.01..0.4).round(3),
                           "replicas" => [ { "client" => "10.0.0.10", "state" => "streaming" } ] },
        "databases" => [ { "name" => "payments_production", "size_bytes" => 18 * GB },
                         { "name" => "storefront_production", "size_bytes" => 6 * GB } ] }
    end

    def journal_block(at)
      entries = Array.new(rand(0..2)) do
        priority, unit, message = JOURNAL_LINES.sample
        { "c" => "s=demo;h=#{name};i=#{SecureRandom.hex(8)}", "t" => (at.to_f * 1_000_000).to_i,
          "p" => priority, "u" => unit, "m" => message }
      end
      { "entries" => entries }
    end
  end
end
