# frozen_string_literal: true

# Keep job diagnostics, but never print arguments or SQL bind values from received content.
module IngestContentLogging
  extend ActiveSupport::Concern

  included do
    self.log_arguments = false
    around_enqueue :without_content_query_logging
    around_perform :without_content_query_logging
  end

  private

  def without_content_query_logging
    logger = ActiveRecord::Base.logger
    if logger
      logger.silence(Logger::INFO) { yield }
    else
      yield
    end
  end
end
