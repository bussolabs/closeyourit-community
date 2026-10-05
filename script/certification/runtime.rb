# frozen_string_literal: true

require_relative "guard"
require_relative "diagnostics"

module Certification
  module Runtime
    def self.boot!
      guard = Guard.new
      run_id = guard.validate!
      require_relative "../../config/environment"
      raise "Certification requires Rails test mode" unless Rails.env.test?

      expected = {
        "primary" => "closeyourit_test_cert_#{run_id}",
        "queue" => "closeyourit_queue_test_cert_#{run_id}",
        "cache" => "storage/test_cache_cert_#{run_id}.sqlite3",
        "cable" => "storage/test_cable_cert_#{run_id}.sqlite3"
      }
      configs = ActiveRecord::Base.configurations.configs_for(env_name: "test", include_hidden: true)
      raise "Unexpected certification database configuration" unless configs.map(&:name).sort == expected.keys.sort

      configs.each do |config|
        options = config.configuration_hash
        unless options[:database] == expected.fetch(config.name) && guard.local_host?(options[:host])
          raise "Certification database is outside the isolated slot"
        end
      end
      # Credentials pass through an anonymous pipe; neither Rails nor SQL may log them.
      diagnostic_directory = Rails.root.join("tmp/certification", run_id)
      FileUtils.mkdir_p(diagnostic_directory)
      Rails.logger = ActiveSupport::Logger.new(Diagnostics.new(diagnostic_directory.join("diagnostics.jsonl")))
      Rails.logger.formatter = ->(_severity, _time, _name, message) { "#{message}\n" }
      Rails.application.config.logger = Rails.logger
      ActiveRecord::Base.logger = Rails.logger
      ActiveJob::Base.logger = Rails.logger
      ActionController::Base.logger = Rails.logger
      ActionController::API.logger = Rails.logger
      SolidQueue.logger = Rails.logger
      ActiveJob::Base.queue_adapter = :solid_queue
      # The test NullStore cannot retain real throttle counters between HTTP requests.
      Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
      Rack::Attack.enabled = true
      run_id
    end
  end
end
