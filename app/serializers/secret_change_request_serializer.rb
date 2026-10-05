# frozen_string_literal: true

# Metadati di una richiesta di modifica ai secret in attesa dell'approvazione a due (CYRA-138/CYRA-230).
# NON espone MAI il valore proposto (cifrato at-rest, come SecretVariableSerializer non espone `value`):
# una change request rivela solo il NOME e l'intento (set/remove), mai il segreto.
class SecretChangeRequestSerializer < ApplicationSerializer
  attributes :id, :name, :action, :status, :reason, :created_at, :decided_at

  attribute :environment do |change_request|
    { id: change_request.environment_id, code: change_request.environment&.code, label: change_request.environment&.label }
  end

  attribute :project do |change_request|
    { id: change_request.project_id, key: change_request.project&.key, name: change_request.project&.name }
  end

  attribute :requested_by do |change_request|
    requester = change_request.requested_by
    requester && { id: requester.id, name: requester.name, email: requester.email }
  end
end
