# frozen_string_literal: true

# Realtime::Presence si appoggia a Rails.cache (Solid Cache in produzione). In ambiente test
# l'app usa :null_store (ogni read → nil, ogni write no-op), quindi i test di presenza sostituiscono
# il cache con un MemoryStore reale e condiviso per la durata dell'esempio. Opt-in, per non toccare
# il comportamento globale: `include_context "realtime presence cache"`.
RSpec.shared_context "realtime presence cache" do
  let(:presence_cache) { ActiveSupport::Cache::MemoryStore.new }

  before { allow(Rails).to receive(:cache).and_return(presence_cache) }
end
