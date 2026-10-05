# frozen_string_literal: true

# Isolamento HTTP: nessun test tocca la rete reale. Provider esterni → VCR/stub.
require "webmock/rspec"

WebMock.disable_net_connect!(allow_localhost: true)
