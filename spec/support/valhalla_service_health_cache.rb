# frozen_string_literal: true

# Valhalla::ProbeServices / Valhalla::SystemHealth#service_statuses si appoggiano a Rails.cache
# (Solid Cache in produzione). In ambiente test l'app usa :null_store (ogni read → nil, ogni write
# no-op, config/environments/test.rb), quindi questi spec sostituiscono il cache con un MemoryStore
# reale per la durata dell'esempio. Stesso pattern di "realtime presence cache"
# (spec/support/realtime_presence_cache.rb). Opt-in: `include_context "valhalla service health cache"`.
RSpec.shared_context "valhalla service health cache" do
  let(:valhalla_service_health_cache) { ActiveSupport::Cache::MemoryStore.new }

  before { allow(Rails).to receive(:cache).and_return(valhalla_service_health_cache) }
end
