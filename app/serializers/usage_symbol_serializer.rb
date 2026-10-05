# frozen_string_literal: true

# CYSK-29 — un simbolo visto in esecuzione, con la sola colonna portante (`last_seen_at`) in testa.
class UsageSymbolSerializer < ApplicationSerializer
  attributes :id, :environment, :kind, :symbol, :first_seen_at, :last_seen_at, :hits_count,
             :last_release, :last_sdk_version
end
