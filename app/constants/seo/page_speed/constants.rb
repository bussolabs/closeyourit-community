# frozen_string_literal: true

module Seo
  module PageSpeed
    # Costanti dell'integrazione PageSpeed Insights (CYRA-539). Nessun magic value sparso nei
    # service (rules/constants.md).
    module Constants
      BASE_URL = "https://pagespeedonline.googleapis.com"
      PATH = "/pagespeedonline/v5/runPagespeed"

      # PSI fa girare Lighthouse su una macchina di Google: è lento per costruzione, decine di
      # secondi. Il timeout di lettura è generoso di proposito; quello di handshake no.
      OPEN_TIMEOUT_SECONDS = 5
      READ_TIMEOUT_SECONDS = 60

      # Le categorie che chiediamo. `pwa` no: non misura niente che riguardi il farsi trovare.
      CATEGORIES = %w[performance accessibility best-practices seo].freeze

      # La maschera dei campi è ciò che rende sostenibile l'integrazione: una risposta completa è
      # mezzo megabyte di report Lighthouse, con la maschera scende a pochi KB. Il client NON deve
      # troncare il body come fa il crawler: un JSON troncato è illeggibile, non è un JSON più corto.
      FIELDS = [
        "id",
        "analysisUTCTimestamp",
        "loadingExperience",
        "originLoadingExperience",
        "lighthouseResult(lighthouseVersion,categories,audits/largest-contentful-paint," \
        "audits/first-contentful-paint,audits/cumulative-layout-shift,audits/total-blocking-time," \
        "audits/speed-index,audits/server-response-time)"
      ].join(",").freeze

      # I nomi degli audit Lighthouse da cui leggiamo le misure, con la colonna che li accoglie.
      LAB_AUDITS = {
        "largest-contentful-paint" => :lab_lcp_ms,
        "first-contentful-paint" => :lab_fcp_ms,
        "total-blocking-time" => :lab_tbt_ms,
        "speed-index" => :lab_speed_index_ms,
        "server-response-time" => :lab_ttfb_ms
      }.freeze

      # Le chiavi delle metriche di campo. NON sono documentate su nessuna pagina ufficiale di
      # Google: sono quelle che l'API manda davvero. Il parser le legge da qui, tollera le chiavi
      # che non conosce e non solleva mai — il giorno che Google ne aggiunge una, la misura in più
      # semplicemente non compare, invece di far fallire il giro.
      FIELD_METRICS = {
        "LARGEST_CONTENTFUL_PAINT_MS" => :field_lcp_ms,
        "INTERACTION_TO_NEXT_PAINT" => :field_inp_ms,
        "FIRST_CONTENTFUL_PAINT_MS" => :field_fcp_ms,
        "EXPERIMENTAL_TIME_TO_FIRST_BYTE" => :field_ttfb_ms
      }.freeze

      # Il CLS di campo arriva come INTERO, moltiplicato per cento: `percentile` è dichiarato int32
      # nell'API e il CLS è decimale, quindi Google lo scala. La divisione vive solo qui.
      CLS_FIELD_KEY = "CUMULATIVE_LAYOUT_SHIFT_SCORE"
      CLS_SCALE = 100.0

      # I punteggi di categoria arrivano in 0..1 (double, e può essere null). Si mostrano in 0..100.
      SCORE_SCALE = 100

      # Categorie Lighthouse → colonne.
      SCORE_COLUMNS = {
        "performance" => :performance_score,
        "accessibility" => :accessibility_score,
        "best-practices" => :best_practices_score,
        "seo" => :seo_score
      }.freeze

      # La lingua dei testi diagnostici della risposta. Non cambia i numeri.
      LOCALE = "it"

      # Interruttore in cache quando Google dice che la quota è finita. Senza, una quota esaurita
      # diventa una riga fallita su ogni sito ogni ora — rumore, non informazione.
      #
      # UNO PER ORGANIZZAZIONE (CYRA-546), non uno per l'installazione: la quota è di chi ha
      # collegato la chiave, e un interruttore solo fermerebbe le misure di tutte le altre
      # organizzazioni per il consumo di una — che pagano con un'altra chiave e non c'entrano niente.
      QUOTA_EXHAUSTED_PREFIX = "seo:psi:quota_exhausted"
      QUOTA_EXHAUSTED_TTL = 1.hour

      def self.quota_exhausted_key(organization_id) = "#{QUOTA_EXHAUSTED_PREFIX}:#{organization_id}"
    end
  end
end
