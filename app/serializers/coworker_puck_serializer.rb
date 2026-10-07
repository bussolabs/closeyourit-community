# frozen_string_literal: true

# A Puck for the apps (CYRA-1022).
class CoworkerPuckSerializer < ApplicationSerializer
  attributes :id, :name, :visibility, :project_id, :created_at
end
