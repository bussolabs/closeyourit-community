# Configurazione Resend (email transazionale via HTTP API) — vedi rules/rails/email.md.
# API key da ENV (CloseYourIt CYRA). Senza RESEND_API_KEY l'invio non è configurato:
# in development si usa letter_opener_web, in test :test — Resend serve solo in produzione.
api_key = ENV["RESEND_API_KEY"]
Resend.api_key = api_key if api_key.present?
