module Coworkers
  # One tool call of a run, kept so a resent call returns the first answer instead of acting twice (CYRA-1009).
  class ToolCall < ApplicationRecord
    self.table_name = "coworkers_tool_calls"
    belongs_to :run, class_name: "Coworkers::Run"
    validates :call_id, presence: true, length: { maximum: 128 }
    validates :name, :args_digest, presence: true
  end
end
