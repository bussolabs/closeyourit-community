# frozen_string_literal: true

module Crashes
  def self.table_name_prefix = "crashes_"

  MAX_FILE = 10.megabytes
  MAX_FILES = 10
  MAX_PROJECT_BYTES = 100.megabytes
  MAX_WIRE = 20.megabytes
  MAX_EXPANDED = 40.megabytes
  MAX_REPORT = 1.megabyte
  REQUEST_SLOTS = SizedQueue.new(2)
  EVENT_ID = /\A[0-9a-f]{32}\z/i
  class Rejected < StandardError; end
  class Unavailable < StandardError; end
end
