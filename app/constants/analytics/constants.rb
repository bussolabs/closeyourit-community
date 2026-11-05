# frozen_string_literal: true

module Analytics
  # Costanti del dominio web analytics (rules/constants.md): pageview cookieless, sessionizzazione,
  # anomalie di traffico e lookup del paese. Le misure di velocità del sito viste dal browser
  # (web vitals) entrano dalla stessa porta e stanno qui; quelle misurate da Google stanno in
  # Seo::PageSpeed::Constants.
  module Constants
    # Retention di default (giorni) — gerarchia god → org → progetto come i log, ma più lunga
    # (l'analytics è storico per natura).
    RETENTION_DEFAULT_DAYS = 365
    # Massimo pageview per singolo POST (oltre → R413). I browser ne inviano 1 alla volta.
    MAX_BATCH = 100

    # Tetto del batch delle misure di velocità (CYRA-538). Più basso dei pageview: un caricamento
    # produce al massimo cinque misure, quindi cinquanta sono già dieci pagine in una richiesta —
    # oltre, è un client che sta accumulando invece di mandare.
    WEB_VITALS_MAX_BATCH = 50

    # Vita del salt giornaliero (giorni); oltre → distrutto dal PruneJob, rendendo i visitor_hash
    # storici irreversibili (postura GDPR cookieless).
    SALT_RETENTION_DAYS = 2
    # Finestra "realtime" della dashboard (visitatori unici correnti).
    REALTIME_WINDOW = 5.minutes
    # Throttle del page-refresh Turbo realtime (per-progetto). Sotto traffico alto emette
    # un solo refresh cable per finestra; Turbo 8 debounce comunque i refresh lato client.
    BROADCAST_THROTTLE = 2.seconds
    # Inattività oltre cui due pageview dello stesso visitatore sono sessioni distinte
    # (sessionizzazione query-time, semantica Plausible). Le sessioni a cavallo di mezzanotte UTC si
    # spezzano (il salt ruota → il visitor_hash cambia): limite noto e accettato, come in Plausible.
    SESSION_GAP = 30.minutes

    # CYRA-147 — rilevamento anomalie di traffico (crollo/picco). Il detector confronta le visite
    # dell'ultima finestra con la media oraria della baseline. Sotto MIN_BASELINE (visite/ora nella
    # baseline) non si dà alcun verdetto: troppo poco traffico per distinguere un crollo dal rumore
    # (limite noto: la stagionalità giorno/notte non è modellata, è un follow-up).
    TRAFFIC_WINDOW = 1.hour
    TRAFFIC_BASELINE_HOURS = 24
    TRAFFIC_DROP_RATIO = 0.25
    TRAFFIC_SPIKE_RATIO = 4.0
    TRAFFIC_MIN_BASELINE = 20

    # Geo: path del database GeoLite2-Country (.mmdb), scaricato a deploy via MAXMIND_LICENSE_KEY su
    # volume Kamal. Assente in dev/test → lookup country degrada a nil.
    GEOIP_DB_PATH = ENV.fetch("GEOIP_DB_PATH", Rails.root.join("storage/GeoLite2-Country.mmdb").to_s)
  end
end
