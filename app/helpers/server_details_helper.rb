# frozen_string_literal: true

# CYRA-703 — lettura del dettaglio non storico dall'ULTIMO campione di una macchina: sensori,
# singoli processori, schede grafiche, interfacce di rete, memoria di scambio, latenze del disco.
# Ha un modulo suo: leggere l'ULTIMO campione è un compito diverso dal disegnare una serie storica,
# e le parti di ServersHelper (CYRA-742) non lo comprendono.
#
# Tutti difensivi allo stesso modo: campione assente, payload monco o valore di tipo sbagliato non
# fanno esplodere la pagina, spariscono e basta. È la stessa regola della pipeline di ingest — un
# agent malconcio non deve poter rompere la scheda di una macchina.
module ServerDetailsHelper
  # [ { name:, value: } ] dal più caldo. Il grafico master mostra il massimo: qui si vede DI CHI è.
  def server_temperature_sensors(last_sample)
    temps = payload_of(last_sample)["temps"]
    return [] unless temps.is_a?(Hash)

    temps.filter_map { |name, value| { name: name.to_s, value: value.to_f } if numeric?(value) }
         .sort_by { |sensor| -sensor[:value] }
  end

  # [ { index:, pct: } ] — l'agent manda le percentuali in ordine di CPU0..CPUn.
  def server_core_usages(last_sample)
    cores = payload_of(last_sample)["cores_usage"]
    return [] unless cores.is_a?(Array)

    cores.each_with_index.filter_map { |pct, i| { index: i, pct: pct.to_f } if numeric?(pct) }
  end

  # L'array [user, system, iowait, steal, idle] con un nome per ciascuna quota. Attesa disco e tempo
  # rubato sono i due numeri che spiegano una macchina lenta con la CPU apparentemente scarica.
  def server_cpu_breakdown(last_sample)
    shares = payload_of(last_sample)["cpu_breakdown"]
    return nil unless shares.is_a?(Array) && shares.size >= 5 && shares.all? { |v| numeric?(v) }

    { user: shares[0].to_f, system: shares[1].to_f, iowait: shares[2].to_f,
      steal: shares[3].to_f, idle: shares[4].to_f }
  end

  # [ { id:, name:, usage_pct:, watt:, memory_used_mb:, memory_total_mb: } ], una voce per scheda.
  # La memoria resta nil dove la scheda non la espone: su GB10 nvidia-smi risponde N/A perché la
  # memoria è unificata con quella di sistema, e uno zero si leggerebbe come "non ne usa".
  def server_gpus(last_sample)
    gpus = payload_of(last_sample)["gpu"]
    return [] unless gpus.is_a?(Hash)

    gpus.filter_map do |id, gpu|
      next unless gpu.is_a?(Hash)

      { id: id.to_s, name: gpu["n"].to_s.presence || id.to_s,
        usage_pct: numeric?(gpu["u"]) ? gpu["u"].to_f : nil,
        watt: numeric?(gpu["p"]) ? gpu["p"].to_f : nil,
        memory_used_mb: numeric?(gpu["mu"]) ? gpu["mu"].to_f : nil,
        memory_total_mb: numeric?(gpu["mt"]) ? gpu["mt"].to_f : nil }
    end
  end

  # per_nic: { nome => [inviati/s, ricevuti/s, totale inviato, totale ricevuto] }.
  def server_network_interfaces(last_sample)
    nics = payload_of(last_sample)["per_nic"]
    return [] unless nics.is_a?(Hash)

    nics.filter_map do |name, values|
      next unless values.is_a?(Array) && values.size >= 4

      { name: name.to_s, sent_bytes: values[2].to_i, recv_bytes: values[3].to_i }
    end
  end

  # nil quando la macchina non ha memoria di scambio: un blocco "0 di 0" è spazio sprecato.
  def server_swap(last_sample)
    swap = payload_of(last_sample)["swap"]
    return nil unless swap.is_a?(Hash)

    total = swap["total_gb"].to_f
    return nil unless total.positive?

    used = swap["used_gb"].to_f
    { used_gb: used, total_gb: total, pct: ((used / total) * 100).round(2) }
  end

  # disk_io_stats: [read time %, write time %, io utilization %, r_await ms, w_await ms, weighted %].
  def server_disk_io(last_sample)
    stats = payload_of(last_sample)["disk_io_stats"]
    return nil unless stats.is_a?(Array) && stats.size >= 5 && stats.all? { |v| numeric?(v) }

    { read_pct: stats[0].to_f, write_pct: stats[1].to_f, util_pct: stats[2].to_f,
      r_await_ms: stats[3].to_f, w_await_ms: stats[4].to_f }
  end

  # Il colore della barra come SIMBOLO. ServersHelper#server_pct_color ritorna una classe CSS
  # ("text-red-600"), che Ui::MeterComponent non sa usare: qui stesse soglie, forma diversa.
  def server_meter_color(pct)
    return :neutral if pct.nil?
    return :red if pct >= ServersHelper::PCT_CRIT
    return :amber if pct >= ServersHelper::PCT_WARN

    :emerald
  end

  private

  def payload_of(last_sample)
    payload = last_sample&.payload
    payload.is_a?(Hash) ? payload : {}
  end

  def numeric?(value) = value.is_a?(Numeric)
end
