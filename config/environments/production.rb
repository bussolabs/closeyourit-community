require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Turn on fragment caching in view templates.
  config.action_controller.perform_caching = true

  # Cache assets for far-future expiry since they are all digest stamped.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # File caricati su S3 (cloud) — il disco del container è ephemeral su Kamal/Docker (rules/rails/storage.md).
  # Secret via ENV/CloseYourIt: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_REGION, AWS_S3_BUCKET.
  # Without a bucket the files go to storage/, which the self-hosted install mounts as a volume (CYRA-916).
  config.active_storage.service = ENV["AWS_S3_BUCKET"].present? ? :amazon : :local

  # SSL terminato da kamal-proxy (reverse proxy davanti all'app).
  config.assume_ssl = true
  config.force_ssl = true

  # Salta il redirect http->https per i controlli interrogati in chiaro da kamal-proxy e dal
  # HEALTHCHECK dell'immagine. Stessa lista dell'esclusione di host_authorization più sotto: le due
  # barriere devono lasciar passare gli stessi path (CloseyouritRails::Application::PROXY_HEALTH_PATHS).
  controlli_dalla_rete_docker = ->(request) { CloseyouritRails::Application::PROXY_HEALTH_PATHS.include?(request.path) }
  config.ssl_options = { redirect: { exclude: controlli_dalla_rete_docker } }

  # Log to STDOUT with the current request id as a default log tag.
  config.log_tags = [ :request_id ]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)

  # Change to "debug" to log everything (including potentially personally-identifiable information!).
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Replace the default in-process memory cache store with a durable alternative.
  config.cache_store = :solid_cache_store

  # Replace the default in-process and non-durable queuing backend for Active Job.
  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :queue } }

  # Email transazionale via Resend (HTTP API). Attiva SOLO con RESEND_API_KEY (CloseYourIt).
  # Senza key (Fase 0b non ancora cablata): nessun invio reale, gli enqueue restano no-op → niente crash.
  # Any SMTP server works too, for self-hosted installs (CYRA-916): SMTP_ADDRESS turns it on.
  if ENV["RESEND_API_KEY"].present?
    config.action_mailer.delivery_method = :resend
    config.action_mailer.perform_deliveries = true
    config.action_mailer.raise_delivery_errors = true
  elsif ENV["SMTP_ADDRESS"].present?
    config.action_mailer.delivery_method = :smtp
    config.action_mailer.smtp_settings = {
      address: ENV["SMTP_ADDRESS"],
      port: ENV.fetch("SMTP_PORT", 587).to_i,
      user_name: ENV["SMTP_USERNAME"].presence,
      password: ENV["SMTP_PASSWORD"].presence,
      authentication: ENV["SMTP_USERNAME"].present? ? ENV.fetch("SMTP_AUTHENTICATION", "plain").to_sym : nil,
      enable_starttls_auto: ENV.fetch("SMTP_STARTTLS", "true") == "true"
    }.compact
    config.action_mailer.perform_deliveries = true
    config.action_mailer.raise_delivery_errors = true
  else
    config.action_mailer.perform_deliveries = false
  end

  # Every host this install answers on, comma separated; the first one is the main address
  # (links in emails, allowed WebSocket origins). Set in config/deploy*.yml or by the installer.
  app_hosts = ENV.fetch("APP_HOSTS", "localhost").split(",").map(&:strip).reject(&:empty?)

  # Host usato nei link generati nei template mailer: MAIL_HOST, altrimenti il primo di APP_HOSTS.
  config.action_mailer.default_url_options = {
    host: ENV.fetch("MAIL_HOST", app_hosts.first),
    protocol: "https"
  }

  # Specify outgoing SMTP server. Remember to add smtp/* credentials via bin/rails credentials:edit.
  # config.action_mailer.smtp_settings = {
  #   user_name: Rails.application.credentials.dig(:smtp, :user_name),
  #   password: Rails.application.credentials.dig(:smtp, :password),
  #   address: "smtp.example.com",
  #   port: 587,
  #   authentication: :plain
  # }

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]

  # Protezione DNS rebinding / Host header. Host serviti da kamal-proxy.
  # The apex that only redirects to www (config/routes/service.rb) must be listed too, or the request
  # dies in host_authorization before the redirect.
  config.hosts = app_hosts

  # Salta la protezione per i controlli che arrivano dalla rete Docker: portano l'Host interno del
  # contenitore, che non è e non può essere fra quelli qui sopra.
  config.host_authorization = { exclude: controlli_dalla_rete_docker }

  # ActionCable (realtime Turbo Streams + presence): dietro kamal-proxy che termina il TLS,
  # l'handshake WebSocket deve avere un Origin negli host serviti, altrimenti è rifiutato PRIMA
  # di ApplicationCable::Connection#connect. Allow esplicito degli stessi host di config.hosts.
  config.action_cable.allowed_request_origins = app_hosts.map { |host| "https://#{host}" }
end
