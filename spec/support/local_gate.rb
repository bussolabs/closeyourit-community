# frozen_string_literal: true

# Ops::LocalGate is process-wide memory: without a reset a lock held by one example would silence
# the next one (CYRA-890).
RSpec.configure do |config|
  config.before { Ops::LocalGate.clear }
end
