# frozen_string_literal: true

module Traces
  module Browse
    Invalid = Class.new(StandardError)
    Unavailable = Class.new(StandardError)
  end
end
