# frozen_string_literal: true

# Chip di riepilogo uptime (up / down / monitors / incident aperti) dell'header condiviso dalle due
# tab Monitor › Uptime (Monitors + Incidents): i conteggi restano IDENTICI cambiando tab. Scoping
# anti-BOLA via visible.monitors (VisibleResources). Usato come before_action solo sulle
# index delle due tab.
module UptimeHeaderStats
  extend ActiveSupport::Concern

  private

  def load_uptime_header_stats
    monitors = visible.monitors
    @total = monitors.count
    # `.fresh`: un monitor col dato vecchio (worker dei controlli fermo) NON conta più come up/down — sarebbe
    # un verde ingannevole — ma resta nel totale, coerente con la riga che lo mostra unknown (CYRA-209).
    @up_count = monitors.status_up.fresh.count
    @down_count = monitors.status_down.fresh.count
    @open_incidents_count = ::Uptime::Incident.top_level
                                              .where(monitor_id: monitors.select(:id), resolved_at: nil).count
  end
end
