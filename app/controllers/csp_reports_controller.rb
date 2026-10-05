# frozen_string_literal: true

# report-uri della Content Security Policy (report-only). Il browser POSTa qui, same-origin, ogni
# risorsa che l'enforce bloccherebbe (font, icone, script...). Raccoglierle server-side permette di
# DIMOSTRARE "zero violazioni" prima di passare a report_only = false (CYRA-229), senza dipendere dalla
# console del browser di un singolo visitatore. Machine POST (Content-Type application/csp-report o
# application/reports+json): eredita da ActionController::API — niente CSRF né allow_browser, che
# scarterebbero la richiesta del browser. Telemetria ONE-WAY: qualunque corpo → 204, non solleva mai.
class CspReportsController < ActionController::API
  # Un report CSP legittimo è piccolo (< 1 KB). Leggiamo al più questo tetto DALLO STREAM (non
  # request.raw_post, che caricherebbe in memoria l'intero corpo): un POST pubblico e senza auth non
  # deve poter esaurire la RAM. Coerente con gli altri ingest del progetto che limitano gli input non
  # fidati (es. CYRA-228, decompressione limitata a MAX+1 byte).
  MAX_REPORT_BYTES = 8_192

  def create
    report = read_report
    Rails.logger.warn("[csp-report] #{report}") if report.present?
    head :no_content
  end

  private

  # Corpo LIMITATO e ripulito prima del log: encoding valido (scrub) e caratteri di controllo
  # neutralizzati. Il body è input non fidato — senza questo, andate a capo o CR permetterebbero di
  # forgiare righe di log false, falsando la conta delle violazioni che serve a dimostrare "zero
  # violazioni" pre-enforce (CWE-117).
  def read_report
    raw = request.body.read(MAX_REPORT_BYTES).to_s
    raw.force_encoding("UTF-8").scrub.gsub(/[[:cntrl:]]+/, " ").strip
  end
end
