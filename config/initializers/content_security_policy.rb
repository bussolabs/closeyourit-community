# Be sure to restart your server when you modify this file.

# Content Security Policy — ENFORCED di default (CYRA-715), in sola raccolta sul canale pubblico
# (Website::BaseController). Nata report-only in CYRA-229 per misurare le violazioni vere senza
# rompere pagine; un browser che segnala e basta però non protegge nessuno, e uno script iniettato
# nell'area utenti veniva eseguito lo stesso. Le violazioni continuano ad arrivare al report-uri.
# Guida: https://guides.rubyonrails.org/security.html#content-security-policy-header
Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    # font-src: :self + data-uri + Google Fonts via gstatic (CYRA-229). Icons are inline SVG: no cdnjs (CYRA-926).
    policy.font_src    :self, :data, "https://fonts.gstatic.com"
    policy.img_src     :self, :data, :https           # avatar, data-uri, screenshot/asset https
    policy.object_src  :none
    policy.script_src  :self                          # importmap: gli inline script prendono il nonce (sotto)
    # style-src: :self + :unsafe_inline (Turbo/utility inline styles) + Google Fonts CSS (CYRA-229).
    policy.style_src   :self, :unsafe_inline, "https://fonts.googleapis.com"
    policy.connect_src :self, :https, "wss:", "ws:"   # ActionCable (Solid Cable) + fetch/XHR (poll, AI)
    policy.base_uri    :self
    # report-uri: il browser POSTa qui (same-origin) ogni violazione, bloccata o solo segnalata
    # (CspReportsController). Serve ancora a due cose: vedere cosa la policy sta bloccando davvero
    # nell'area utenti, e misurare il canale pubblico prima di passare all'enforce anche lì.
    policy.report_uri  "/csp-reports"
    # frame_ancestors :self — nessuno deve poter incorniciare le nostre pagine per far premere a un
    # utente loggato un bottone che non vede (clickjacking). Le pagine fatte apposta per stare in un
    # iframe altrui (badge e status page pubbliche) la tolgono da sé insieme a X-Frame-Options, nello
    # stesso punto: Website::BaseController#allow_iframe_embedding.
    policy.frame_ancestors :self
  end

  # Nonce per gli inline script di importmap (javascript_importmap_tags lo applica da sé). SOLO script:
  # su style-src il nonce disattiverebbe :unsafe_inline (spec CSP) rompendo la progress-bar di Turbo.
  #
  # CYRA-715 — casuale A OGNI RICHIESTA, non più l'id di sessione (che è quello suggerito dai commenti
  # generati da Rails). Un nonce che dura quanto la sessione si legge una volta e si riusa per
  # settimane: chi riesce a iniettare markup può firmarci i propri script e la policy lo autorizza.
  # Peggio, sulle pagine pubbliche la sessione non è ancora nata e `session.id` è nil → il nonce
  # usciva VUOTO, cioè `'nonce-'`, che non autorizza niente e non protegge niente.
  #
  # Con Turbo si può fare perché turbo-rails azzera l'attributo `nonce` prima di confrontare gli
  # elementi dell'head (`elementWithoutNonce`): un nonce diverso a ogni pagina non fa più sembrare
  # "cambiato" lo script `data-turbo-track="reload"` dell'importmap, che altrimenti trasformerebbe
  # ogni navigazione in un ricaricamento completo. Il costo reale è un altro: il corpo dell'HTML
  # cambia sempre, quindi le pagine non si rivalidano più con un 304.
  config.content_security_policy_nonce_generator = ->(_request) { SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w[script-src]

  # Blocca davvero. Il canale pubblico (Website::) resta in sola raccolta: le sue pagine sono
  # incollate e incorniciate in casa d'altri, dove un blocco non lo vedrebbe nessuno di noi.
  config.content_security_policy_report_only = false
end
