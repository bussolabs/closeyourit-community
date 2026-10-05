# frozen_string_literal: true

module Clusters
  # A Warning event reported by the observer, kept for 48 hours (CYAG-22).
  class Event < ApplicationRecord
    belongs_to :cluster, class_name: "Clusters::Cluster", inverse_of: :events
  end
end
