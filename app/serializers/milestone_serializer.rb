# frozen_string_literal: true

class MilestoneSerializer < ApplicationSerializer
  attributes :id, :project_id, :code, :label, :color, :due_on, :active, :position, :created_at
end
