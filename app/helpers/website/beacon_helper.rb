# frozen_string_literal: true

module Website
  # CYRA-238 — il sito pubblico misura se stesso come lo misurerebbe un cliente: un pageview per
  # navigazione verso il progetto CloseYourIt, con la stessa chiave pubblica degli SDK del browser.
  # Senza configurazione lo script non viene emesso affatto: nessuna richiesta, nessun errore
  # (CYRA-742).
  module BeaconHelper
    # Beacon self-analytics (CYRA-238, dogfooding): un pageview per navigazione verso il progetto
    # CloseYourIt stesso, autenticato con la DSN public key (non segreta, ?sentry_key=) — lo stesso
    # meccanismo degli SDK browser (Api::V1::IngestBaseController). Config da ENV
    # (WEBSITE_ANALYTICS_PROJECT_ID/_KEY): se assente lo script NON viene emesso — no-op silenzioso,
    # come il client closeyourit-ruby senza token, nessuna richiesta e nessun errore JS.
    #
    # Un solo listener (turbo:load, che Turbo Drive spara anche sul primo caricamento pagina): NON
    # anche `load`, altrimenti la prima visita manderebbe due beacon.
    def website_analytics_beacon_tag
      project_id = ENV["WEBSITE_ANALYTICS_PROJECT_ID"].presence
      public_key = ENV["WEBSITE_ANALYTICS_KEY"].presence
      return unless project_id && public_key

      # Path grezzo (come nelle spec dell'endpoint, spec/requests/api/v1/pageviews_spec.rb): niente
      # route helper, l'endpoint di ingest non ne espone uno dedicato per il canale pubblico.
      query = URI.encode_www_form(sentry_key: public_key)
      url = "/api/v1/projects/#{ERB::Util.url_encode(project_id)}/pageviews?#{query}"

      javascript_tag(nonce: true) do
        raw(<<~JS)
          (function () {
            function sendPageview() {
              var body = JSON.stringify({
                name: "pageview",
                path: location.pathname,
                hostname: location.hostname,
                referrer: document.referrer
              });
              if (navigator.sendBeacon) {
                navigator.sendBeacon(#{url.to_json}, new Blob([body], { type: "application/json" }));
              } else {
                fetch(#{url.to_json}, { method: "POST", body: body, keepalive: true, headers: { "Content-Type": "application/json" } });
              }
            }
            document.addEventListener("turbo:load", sendPageview);
          })();
        JS
      end
    end
  end
end
