# frozen_string_literal: true

# travel_to / freeze_time nei test (rules/test-boundaries.md §tempo).
RSpec.configure do |config|
  config.include ActiveSupport::Testing::TimeHelpers
end
