# The test environment is used exclusively to run your application's
# test suite. You never need to work with it otherwise. Remember that
# your test database is "scratch space" for the test suite and is wiped
# and recreated between test runs. Don't rely on the data there!

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # While tests run files are not watched, reloading is not necessary.
  config.enable_reloading = false

  # Eager loading loads your entire application. When running a single test locally,
  # this is usually not necessary, and can slow down your test suite. However, it's
  # recommended that you enable it in continuous integration systems to ensure eager
  # loading is working properly before deploying your code.
  config.eager_load = ENV["CI"].present?

  # Configure public file server for tests with cache-control for performance.
  config.public_file_server.headers = { "cache-control" => "public, max-age=3600" }

  # Show full error reports.
  config.consider_all_requests_local = true
  config.cache_store = :null_store

  # Render exception templates for rescuable exceptions and raise for other exceptions.
  config.action_dispatch.show_exceptions = :rescuable

  # Disable request forgery protection in test environment.
  config.action_controller.allow_forgery_protection = false

  # Store uploaded files on the local file system in a temporary directory.
  config.active_storage.service = :test

  # Tell Action Mailer not to deliver emails to the real world.
  # The :test delivery method accumulates sent emails in the
  # ActionMailer::Base.deliveries array.
  config.action_mailer.delivery_method = :test

  # Set host to be used by links generated in mailer templates.
  config.action_mailer.default_url_options = { host: "example.com" }

  # Job enqueued (non eseguiti) nei test: permette gli assert have_enqueued_mail.
  config.active_job.queue_adapter = :test

  # L'adapter resta `:test` (nessun job viene eseguito davvero), ma i MODELLI di Solid Queue devono
  # puntare al database queue come in development e production: senza, cercano le proprie tabelle
  # sul primary, dove non esistono, e non è testabile nulla che le legga — per esempio la retention
  # delle esecuzioni fallite.
  config.solid_queue.connects_to = { database: { writing: :queue } }

  # Solo avvisi ed errori nel registro: scrivere ogni query costava circa il 5% del tempo delle
  # prove. Per il debug locale: RAILS_LOG_LEVEL=debug (CYRA-854).
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "warn")

  # Print deprecation notices to the stderr.
  config.active_support.deprecation = :stderr

  # Raises error for missing translations.
  # config.i18n.raise_on_missing_translations = true

  # Annotate rendered view with file names.
  # config.action_view.annotate_rendered_view_with_filenames = true

  # Raise error when a before_action's only/except options reference missing actions.
  config.action_controller.raise_on_missing_callback_actions = true

  # ActiveRecord::Encryption — chiavi fisse di test (NON segrete: il DB di test è scratch space).
  # Deterministiche così i test non dipendono da un vault esterno (mai rspec sotto un secret runner).
  config.active_record.encryption.primary_key = "test_ar_encryption_primary_key_do_not_use_in_prod"
  config.active_record.encryption.deterministic_key = "test_ar_encryption_deterministic_do_not_use_in_prod"
  config.active_record.encryption.key_derivation_salt = "test_ar_encryption_key_derivation_salt_do_not_use_prod"
end
