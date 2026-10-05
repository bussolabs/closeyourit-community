# frozen_string_literal: true

# CYRA-776 — l'incident si apriva al PRIMO controllo andato storto, e partiva l'avviso; al giro dopo
# il sito rispondeva, l'incident si chiudeva e partiva il rientro. Due notifiche per un inciampo di
# rete: fra il 2026-08-31 e il 2026-09-04 tutti gli incident di tre siti monitorati
# si sono aperti e chiusi entro sessanta secondi (15 aperture, 14 chiusure, nessun
# disservizio reale). `failure_threshold` è quanti controlli falliti DI FILA servono per dichiarare
# il sito irraggiungibile (2 di default: un minuto di ritardo su un guasto vero costa molto meno del
# rumore che toglie); `consecutive_failures` è il contatore che la alimenta, scritto da
# Uptime::RecordCheck nella stessa transazione del check, sotto il lock del monitor.
#
# I monitor esistenti prendono il default: la conferma si accende ovunque. Chi ha un incident già
# aperto non è toccato — la chiusura resta al primo successo, e il contatore riparte da zero.
class AddFailureThresholdToUptimeMonitors < ActiveRecord::Migration[8.1]
  def change
    add_column :uptime_monitors, :failure_threshold, :integer, default: 2, null: false
    add_column :uptime_monitors, :consecutive_failures, :integer, default: 0, null: false
  end
end
