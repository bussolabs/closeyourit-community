require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
require "action_mailbox/engine"
require "action_text/engine"
require "action_view/railtie"
require "action_cable/engine"
# require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module CloseyouritRails
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # I path interrogati DALLA RETE DOCKER — kamal-proxy al rollout e il HEALTHCHECK dell'immagine.
    # Arrivano in chiaro e con l'Host interno del contenitore (`closeyourit-web-<versione>`), che non
    # è nessuno degli host serviti: in produzione `config.hosts` è popolato, quindi senza esclusione
    # la richiesta muore in host_authorization con un 403 e il rollout fallisce anche con tutto sano.
    # `force_ssl` aggiungerebbe un redirect a https, che un controllo di salute non segue.
    #
    # Stanno QUI, in un elenco solo, perché le due esclusioni di production.rb (`ssl_options` e
    # `host_authorization`) devono nominare gli STESSI path: se divergono il controllo passa una
    # barriera e muore sull'altra, e il motivo non si legge da nessuna parte. `/up` è il HEALTHCHECK
    # dell'immagine (e quindi il risveglio di Sablier su staging); `/up/database` è il controllo di
    # prontezza del rilascio (CYRA-754, `proxy.healthcheck` in config/deploy.yml).
    PROXY_HEALTH_PATHS = %w[/up /up/database].freeze

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # Timezone — app in Europe/Rome, DB sempre UTC.
    config.time_zone = "Rome"
    config.active_record.default_timezone = :utc

    # i18n — default inglese, fallback italiano, locali per dominio in config/locales/**.
    config.i18n.default_locale = :en
    config.i18n.fallbacks = [ :it ]
    # CYRA-372 — le pagine di errore le rende l'applicazione (ErrorsController), non i file statici:
    # in italiano, col menu quando la sessione c'è, e con una via d'uscita. I file in public/
    # restano come rete per quando Rails non gira affatto.
    config.exceptions_app = routes

    # Ingest jobs carry whole payloads in their arguments: one hour of finished jobs is enough for
    # Ops::QueueThroughput (10 minutes) and keeps the queue database small (CYRA-896).
    config.solid_queue.clear_finished_jobs_after = 1.hour

    config.i18n.load_path += Dir[Rails.root.join("config/locales/**/*.yml")]

    # ActiveRecord::Encryption — cifratura reversibile at-rest per il dominio Secrets:: (vault).
    # Chiavi di bootstrap da ENV gestite dall'operatore in staging/production; il fallback locale
    # (non segreto) vive in config/environments/{development,test}.rb così rspec e dev sono autonomi.
    # MAI credentials.yml.enc: soltanto queste chiavi passano dal canale di bootstrap esterno.
    if ENV["AR_ENCRYPTION_PRIMARY_KEY"].present?
      config.active_record.encryption.primary_key = ENV.fetch("AR_ENCRYPTION_PRIMARY_KEY")
      config.active_record.encryption.deterministic_key = ENV.fetch("AR_ENCRYPTION_DETERMINISTIC_KEY")
      config.active_record.encryption.key_derivation_salt = ENV.fetch("AR_ENCRYPTION_KEY_DERIVATION_SALT")
    end

    # Generators — RSpec, niente helper/view/routing spec, factory_bot.
    # UUID come primary key e foreign key di default (rules/rails/models.md).
    config.generators do |g|
      g.orm :active_record, primary_key_type: :uuid
      g.test_framework :rspec,
        fixtures: true,
        view_specs: false,
        helper_specs: false,
        routing_specs: false
      g.fixture_replacement :factory_bot, dir: "spec/factories"
    end

    # Don't generate system test files.
    config.generators.system_tests = nil
  end
end
