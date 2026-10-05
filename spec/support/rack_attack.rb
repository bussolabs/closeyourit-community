# frozen_string_literal: true

# rack-attack disattivato nei test: throttle/blocklist non devono interferire con le suite
# (rules/rails/security.md).
RSpec.configure do |config|
  config.before(:suite) { Rack::Attack.enabled = false }
end
