# frozen_string_literal: true

module Servers
  # I DISCHI di una macchina e i byte in generale: quanto è grande il totale che conosciamo, quali
  # volumi ha, quanto ne resta libero. Da qui esce anche l'unico formato dei byte usato in pagina,
  # perché "18,4 GB · 57%" deve leggersi uguale ovunque compaia (CYRA-742).
  module FilesystemsHelper
    # Valore di una metrica scritto per esteso: temperatura in °C, percentuale nuda quando non sappiamo
    # su cosa insiste, assoluto + percentuale quando conosciamo i byte ("18,4 GB · 57%"). Unico
    # formatter di questo valore, condiviso fra il numero in testata e la riga del tooltip.
    # `used_bytes` è la misura vera del blocco e vince sempre; senza (agent che non manda il dettaglio)
    # si ripiega su pct × totale attuale, che è esatto finché la macchina non cambia taglio.
    def server_current_text(value, temp: false, total_bytes: nil, used_bytes: nil)
      return server_temp_text(value) if temp
      return server_pct_text(value) if value.nil?

      absolute = used_bytes || (total_bytes.to_i.zero? ? nil : (total_bytes * value / 100.0).round)
      return server_pct_text(value) if absolute.nil?

      "#{server_bytes_text(absolute)} · #{server_pct_text(value)}"
    end

    GIBIBYTE = 1_073_741_824

    # Totale della macchina per la metrica, in byte, se lo conosciamo: la memoria ha una colonna
    # denormalizzata sull'host, il disco vive solo nel payload dell'ultimo campione (l'agent lo manda in
    # GiB, come la percentuale è quella del filesystem root — stessa fonte, quindi confrontabili).
    # nil = totale ignoto: il grafico resta in sola percentuale invece di inventarsi un fondo scala.
    def server_metric_total_bytes(metric, host, last_sample = nil)
      case metric.to_sym
      when :mem then host.memory_total_bytes || server_payload_total_bytes(last_sample, "mem")
      when :disk then server_payload_total_bytes(last_sample, "disk")
      end
    end

    def server_payload_total_bytes(last_sample, key)
      payload = last_sample&.payload
      total = payload.is_a?(Hash) ? payload.dig(key, "total_gb") : nil
      return nil if total.to_f.zero?

      (total.to_f * GIBIBYTE).round
    end

    # I dischi della macchina, dal payload dell'ultimo campione: il disco di sistema per primo (è quello
    # e SOLO quello a cui si riferisce la percentuale del grafico — l'agent calcola DiskPct sul filesystem
    # root), poi i volumi dati. Gli extra li scopre da solo l'agent per ogni partizione su block device
    # montata fuori dalla root (es. /mnt/pgdata), quindi l'elenco non richiede configurazione.
    # Ritorna [{ name:, root:, total_bytes:, used_bytes:, free_bytes:, pct:, inode_pct: }], vuoto se manca
    # il payload. Il nome degli extra è il device (o il nome scelto con EXTRA_FILESYSTEMS): l'agent non
    # manda il mountpoint, quindi qui non possiamo dire DOVE è montato un volume.
    def server_filesystems(host, last_sample = nil)
      payload = last_sample&.payload
      return [] unless payload.is_a?(Hash)

      root = server_filesystem_entry(t("member.servers.show.disk_root"), payload["disk"], root: true)
      extra = Hash(payload["extra_fs"]).filter_map { |name, fs| server_filesystem_entry(name, fs, root: false) }
      [ root, *extra ].compact
    end

    def server_filesystem_entry(name, fs, root:)
      return nil unless fs.is_a?(Hash)

      total = fs["total_gb"] || fs["d"]
      used = fs["used_gb"] || fs["du"]
      return nil if total.to_f.zero?

      total_bytes = (total.to_f * GIBIBYTE).round
      used_bytes = (used.to_f * GIBIBYTE).round
      { name: name.to_s, root: root, total_bytes: total_bytes, used_bytes: used_bytes,
        free_bytes: [ total_bytes - used_bytes, 0 ].max, pct: (used.to_f * 100.0 / total.to_f).round(1),
        inode_pct: server_inode_pct(fs) }
    end

    # CYRA-515 — gli inode si esauriscono a spazio ancora libero (tanti file minuscoli), e l'avviso
    # «inode quasi esauriti» nomina il mount: senza questo numero in pagina non c'era modo di
    # verificarlo né di vedere gli altri mount. Chiave `inode_pct` sul disco di sistema, `ip` sugli
    # extra (l'agent li scrive così). Assente = la macchina non lo riporta: non si mostra nulla, non
    # si scrive zero.
    def server_inode_pct(fs)
      value = fs["inode_pct"] || fs["ip"]
      value&.to_f&.round(1)
    end

    # "21.8 GB liberi su 42 GB" — il libero prima del totale: è il numero su cui si decide se intervenire.
    def server_filesystem_free_text(entry)
      t("member.servers.show.disk_free",
        free: server_bytes_text(entry[:free_bytes]), total: server_bytes_text(entry[:total_bytes]))
    end

    # Byte umani per rete/memoria container (delta per intervallo → rate approssimato al minuto).
    def server_bytes_text(bytes)
      return "—" if bytes.nil?

      number_to_human_size(bytes)
    end
  end
end
