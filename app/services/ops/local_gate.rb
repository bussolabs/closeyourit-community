# frozen_string_literal: true

module Ops
  # Process-local memory of shared-cache locks this process already knows are held. On Solid Cache
  # every `write(unless_exist:)` is a SELECT ... FOR UPDATE, so hot paths ask here first (CYRA-890).
  module LocalGate
    STORE = ActiveSupport::Cache::MemoryStore.new(size: 4.megabytes)

    module_function

    def held?(key) = STORE.exist?(key)
    def hold(key, expires_in:) = STORE.write(key, true, expires_in:)
    def release(key) = STORE.delete(key)
    def clear = STORE.clear
  end
end
