# frozen_string_literal: true

module Servers
  # Media oraria dei campioni raw in scadenza (CYRA-679): scritta da Servers::PruneJob subito prima
  # del delete, così la storia sopravvive alla retention raw. Immutabile come i campioni; idempotente
  # su [host, bucket_at] (il retry del prune non duplica). Solo hot column: il dettaglio jsonb muore
  # con il raw, com'è giusto per un dato di baseline.
  class SampleRollup < ApplicationRecord
    belongs_to :host, class_name: "Servers::Host"
    belongs_to :organization, class_name: "Organizations::Organization"

    validates :bucket_at, presence: true
  end
end
