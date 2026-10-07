source "https://rubygems.org"

ruby "~> 4.0"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 8.1.3"
# The modern asset pipeline for Rails [https://github.com/rails/propshaft]
gem "propshaft"
# Use postgresql as the database for Active Record (primary + queue)
gem "pg", "~> 1.7"
# Nearest-neighbor search su pgvector (colonne vector + has_neighbor) — ricerca semantica
gem "neighbor"
# Rendering markdown (GFM) delle pagine Knowledge — output safe (raw HTML escapato)
gem "commonmarker", "~> 2.10"
# SQLite per i database Solid Cache + Solid Cable
gem "sqlite3", ">= 2.1"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"
# Use JavaScript with ESM import maps [https://github.com/rails/importmap-rails]
gem "importmap-rails"
# Hotwire's SPA-like page accelerator [https://turbo.hotwired.dev]
gem "turbo-rails"
# Hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem "stimulus-rails"
# Use Tailwind CSS [https://github.com/rails/tailwindcss-rails]
gem "tailwindcss-rails"
# Build JSON APIs with ease [https://github.com/rails/jbuilder]
gem "jbuilder"
gem "msgpack", "~> 1.8", ">= 1.8.5"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
gem "bcrypt", "~> 3.1.7"

# 2FA TOTP (CYRA-170): rotp genera/verifica i codici a tempo (RFC 6238), rqrcode disegna il QR di
# provisioning per le app authenticator. Entrambe pure-ruby, nessuna dipendenza nativa.
gem "rotp", "~> 6.3"
gem "rqrcode", "~> 3.0"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Use the database-backed adapters for Rails.cache, Active Job, and Action Cable
gem "solid_cache"
gem "solid_queue"
# Next run of a Puck schedule in its time zone (CYRA-1001); also what Solid Queue uses for recurring jobs.
gem "fugit"
gem "solid_cable"

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Deploy this application anywhere as a Docker container [https://kamal-deploy.org]
gem "kamal", "~> 2.11", require: false

# Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
gem "thruster", require: false

# Email transazionale via Resend (HTTP API) in produzione — vedi rules/rails/email.md
gem "resend"

# Use Active Storage variants [https://guides.rubyonrails.org/active_storage_overview.html#transforming-images]
gem "image_processing", "~> 2.2"
# Backend di image_processing: da Rails 8.1.3.1 ActiveStorage carica `image_processing/vips` all'avvio
# (il require serve a disattivare i loader non-fuzzati di libvips), e senza questa gem il boot muore con
# LoadError — il messaggio non combacia col rescue del framework, quindi non degrada in warning, esplode.
# libvips è già installata nell'immagine (Dockerfile) e il variant_processor resta il default (:vips).
gem "ruby-vips", "~> 2.0"

# Cloud storage S3 per ActiveStorage in produzione/staging — vedi rules/rails/storage.md
gem "aws-sdk-s3", require: false

# Geolocalizzazione IP → country per analytics (lettura file GeoLite2 .mmdb, offline, inline nel
# controller ingest prima di scartare l'IP). Solo il lettore mmdb, nessun web service.
gem "maxmind-db"

# Lettura di HTML e XML altrui (cockpit SEO: pagine visitate e sitemap). Arrivava già come
# dipendenza indiretta di rails-html-sanitizer, ma dipendere da una transitiva significa perderla
# senza preavviso al primo aggiornamento di quel ramo: qui la usiamo, quindi la dichiariamo.
gem "nokogiri"

# JSON serialization
gem "alba"
gem "json_schemer" # validazione dei result agente contro il contract vendored (agent-result/v1) + contract spec

# UI components [https://viewcomponent.org]
gem "view_component"
# Outline icons rendered as inline SVG by Ui::IconComponent (CYRA-926)
gem "lucide-rails", "= 0.7.4"

# Rate limiting / abuse protection
gem "rack-attack"

# CORS per gli endpoint di ingest consumati dagli SDK browser (closeyourit-js)
gem "rack-cors"

# Self-monitoring: errori, job, log e query lente passano dal server ingest indipendente.
gem "closeyourit-ruby", "~> 0.10.2"

# Sealed box (libsodium) per cifrare i secret con la public key GitHub prima del push (Secrets vault Fase 2).
# Richiede libsodium a livello OS (Dockerfile: libsodium23 runtime + libsodium-dev build; macOS: brew libsodium).
gem "rbnacl"

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  # Audits gems for known security defects (use config/bundler-audit.yml to ignore issues)
  gem "bundler-audit", require: false

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false

  # Test framework + factories
  gem "rspec-rails"
  gem "factory_bot_rails"
  gem "faker"
  gem "dotenv-rails"
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"

  # Preview sent emails in the browser
  gem "letter_opener_web"

  # Component catalog / preview [https://lookbook.build]
  gem "lookbook", "~> 2.3"
end

group :test do
  gem "capybara"
  gem "parallel_tests"
  gem "selenium-webdriver"
  gem "vcr"
  gem "webmock"
  gem "simplecov", require: false
  gem "simplecov-lcov", require: false
  gem "prosopite"
  gem "pg_query"
end
