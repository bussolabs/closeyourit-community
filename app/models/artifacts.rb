# frozen_string_literal: true

module Artifacts
  def self.table_name_prefix = "artifacts_"

  MAX_REQUEST = 10.megabytes
  MAX_MAP = 5.megabytes
  MAX_PROGUARD_MAP = 8.megabytes
  MAX_PROJECT_BYTES = 100.megabytes
  MAX_SEGMENTS = 100_000
  MAX_SOURCES = 10_000
  MAX_NAMES = 10_000
  MAX_FUNCTIONS = 10_000
  MAX_SECTIONS = 100
  MAX_DEPTH = 4
  MAX_POSITION = 2**31 - 1
  UPLOAD_SLOTS = SizedQueue.new(2)
  Rejected = Class.new(StandardError)
  Conflict = Class.new(StandardError)
  Unavailable = Class.new(StandardError)
end
