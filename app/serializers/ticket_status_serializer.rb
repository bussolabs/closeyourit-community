# frozen_string_literal: true

class TicketStatusSerializer < ApplicationSerializer
  attributes :id, :code, :label, :color, :position, :active, :animated
end
