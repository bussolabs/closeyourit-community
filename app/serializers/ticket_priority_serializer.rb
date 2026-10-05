# frozen_string_literal: true

class TicketPrioritySerializer < ApplicationSerializer
  attributes :id, :code, :label, :color, :position, :active
end
