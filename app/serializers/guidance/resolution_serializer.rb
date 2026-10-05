# frozen_string_literal: true

module Guidance
  # Serializza il contesto risolto da Guidance::Resolve (una Resolution con references e procedures già
  # composte per il progetto). Ogni elemento porta la sua origine (`level`: organization/group/project),
  # come richiesto dal DoD di CYRA-74. Gli elementi sono Data → to_h dà l'hash piatto dei loro campi.
  class ResolutionSerializer < ApplicationSerializer
    attribute(:references) { |resolution| resolution.references.map(&:to_h) }
    attribute(:procedures) { |resolution| resolution.procedures.map(&:to_h) }
  end
end
