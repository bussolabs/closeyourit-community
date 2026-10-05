# frozen_string_literal: true

module Ticketing
  # Serializza lo snapshot immutabile della Guidance consegnata alla presa in carico (CYRA-76) per il
  # canale d'audit CLI. Espone il payload risolto (references + procedures, ciascuna con la sua origine
  # `level` all'interno), la versione dello schema, il digest, il timestamp e l'attore snapshottato:
  # insieme ricostruiscono le istruzioni consegnate.
  class WorkContextSnapshotSerializer < ApplicationSerializer
    attributes :id, :payload_version, :digest, :generated_at, :actor_name

    attribute(:payload) { |snapshot| snapshot.payload }
  end
end
