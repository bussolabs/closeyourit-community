# frozen_string_literal: true

module Secrets
  # «Valore in comune» (CYRA-777): riconoscere che lo stesso valore segreto è stato ricopiato a mano
  # in più progetti della stessa organizzazione, e proporre di spostarlo una volta sola nei secret
  # dell'organizzazione delegandolo a chi lo usava. Namespace condiviso fra il modello della proposta
  # (qui) e i servizi che la calcolano e la applicano (app/services/secrets/consolidation/), come già
  # per Secrets::Shared.
  module Consolidation
    def self.table_name_prefix = "secrets_consolidation_"
  end
end
