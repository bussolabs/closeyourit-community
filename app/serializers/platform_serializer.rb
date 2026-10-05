# frozen_string_literal: true

class PlatformSerializer < ApplicationSerializer
  attributes :id, :code, :label, :color, :position, :active, :supports_uptime
end
