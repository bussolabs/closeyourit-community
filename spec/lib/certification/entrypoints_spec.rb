# frozen_string_literal: true

require "spec_helper"
require "open3"

RSpec.describe "Certification process boundaries" do
  %w[prepare server worker].each do |entrypoint|
    it "rejects production before #{entrypoint} loads Rails or connects to a database" do
      path = File.expand_path("../../../script/certification/#{entrypoint}.rb", __dir__)
      stdout, stderr, status = Open3.capture3({ "RAILS_ENV" => "production" }, RbConfig.ruby, path, unsetenv_others: true)
      expect(status).not_to be_success
      expect(stdout).to be_empty
      expect(stderr).to include("Certification requires the test environment")
      expect(stderr).not_to include("config/environment")
    end

    it "rejects an injected database URL before #{entrypoint} starts without printing its value" do
      path = File.expand_path("../../../script/certification/#{entrypoint}.rb", __dir__)
      env = { "RAILS_ENV" => "test", "CERTIFICATION_RUN_ID" => "a123456789abcdef",
              "TEST_SLOT" => "_cert_a123456789abcdef", "DATABASE_URL" => "postgres://private.example/sensitive" }
      stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, path, unsetenv_others: true)
      expect(status).not_to be_success
      expect(stdout).to be_empty
      expect(stderr).to include("Database connection overrides are not allowed")
      expect(stderr).not_to include("private.example", "sensitive")
    end
  end
end
