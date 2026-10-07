module Coworkers
  # One thing a Puck asked a person's computer to do; the person says yes or no there (CYRA-1029).
  class DeviceCall < ApplicationRecord
    self.table_name = "coworkers_device_calls"
    TOOLS = %w[list_files read_file run_command].freeze
    STATUSES = %w[pending delivered done denied failed expired].freeze

    belongs_to :device, class_name: "Coworkers::Device"
    belongs_to :run, class_name: "Coworkers::Run"
    validates :tool, inclusion: { in: TOOLS }
    validates :status, inclusion: { in: STATUSES }
  end
end
