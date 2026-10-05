# frozen_string_literal: true

module App
  module Version
    module_function

    def app = "closeyourit-rails"
    def tag = ENV.fetch("APP_GIT_TAG", "unknown")
    def sha = ENV.fetch("APP_GIT_SHA", "unknown")
    def short_sha = sha == "unknown" ? "unknown" : sha[0, 7]
    def build_time = ENV.fetch("APP_BUILD_TIME", "unknown")
    def environment = ENV.fetch("CLOSEYOURIT_ENVIRONMENT", Rails.env.to_s)

    def to_h
      { app:, tag:, sha:, short_sha:, build_time:, environment:,
        ruby_version: RUBY_VERSION, rails_version: Rails::VERSION::STRING }
    end
  end
end
