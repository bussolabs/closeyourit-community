# frozen_string_literal: true

module Ops
  # Giro periodico (recurring.yml, ogni minuto in produzione) che interroga il canarino della cache
  # (Ops::CacheCanary) e, se la cache condivisa non è raggiungibile, logga un WARN. È la traccia che
  # chiude il buco di CYRA-270: quando la cache va in lock durante un picco, i freni anti-doppione degli
  # avvisi la scambiano per «già avvisato» e tacciono, e l'eccezione di lock è esclusa dal
  # self-monitoring (anti-ricorsione) — senza questo giro il degrado non lascerebbe alcun segnale.
  #
  # Sola OSSERVAZIONE: non tocca i gate (un fail-open lì vanificava i rate-limiter, ritirato in
  # v0.70.2) e non ripara. Da CYRA-846 il segnale non resta nei soli log: parte anche un avviso
  # `cache_unavailable` per ogni organizzazione, perché il WARN lo legge solo chi sta già guardando i
  # log. Il WARN si ripete ad ogni giro finché dura l'indisponibilità (un segnale al minuto, nessuna
  # amplificazione per-occorrenza); l'avviso no — il throttle della regola di default lo collassa a
  # circa uno l'ora. Il canarino cattura ogni errore internamente, quindi il perform non solleva e il
  # retry di ApplicationJob non scatta.
  #
  # Corsia :default (real-time, 3 thread, isolata dall'AI in config/queue.yml). Quando è nato,
  # :maintenance aveva un solo thread condiviso coi training AI (fino a un'ora) e coi giri notturni
  # pesanti: un lavoro lungo in corso avrebbe tenuto il canarino in coda per un'ora, facendogli mancare
  # proprio l'indisponibilità durante un sovraccarico. Da CYRA-714 quella corsia serve solo i controlli,
  # ma il canarino resta qui: deve suonare quando qualcosa va storto, e :default ha più slot e meno
  # giri periodici addosso. È anche prioritaria su :ingest, quindi nemmeno un picco d'ingest lo affama.
  class CacheCanaryJob < ApplicationJob
    queue_as :default

    EVENT = "cache_unavailable"

    def perform
      result = Ops::CacheCanary.call
      return if result.available?

      Rails.logger.warn(
        "Ops::CacheCanaryJob cache condivisa non raggiungibile: #{result.error} — i freni anti-doppione " \
        "degli avvisi (spike errori, soglia metriche, canali) possono sopprimere i segnali in silenzio."
      )
      notify(result.error)
    end

    private

    # CYRA-846 — the WARN is read only by whoever is already watching the logs. The alert is a platform
    # alert (CYRA-875): it reaches only the gods, and in-app and email do not depend on the cache.
    def notify(error) = Alerting::PlatformAlert.notify(event_type: EVENT, value: error)
  end
end
