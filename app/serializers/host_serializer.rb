# frozen_string_literal: true

# Snapshot di un Servers::Host per il canale CLI (fleet + show). Espone le colonne denormalizzate
# dell'ultimo campione; i jsonb di dettaglio (systemd/SMART) restano fuori dal contratto CLI v1.
class HostSerializer < ApplicationSerializer
  attributes :id, :name, :hostname, :fingerprint, :status,
             :cpu_pct, :mem_pct, :disk_pct, :temp_max,
             :load_1, :load_5, :load_15,
             :cores, :threads, :cpu_model, :arch, :kernel, :os_name, :memory_total_bytes,
             :containers_count, :services_total, :services_failed,
             :reboot_required, :updates_available,
             :agent_version, :uptime_seconds, :last_seen_at, :revoked_at, :created_at,
             # CYRA-519 — i nomi che su questa macchina non sono servizi: si leggono e si scrivono
             # anche da terminale, non solo dalla pagina web.
             :ignored_container_patterns
end
