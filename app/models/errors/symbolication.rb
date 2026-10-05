# frozen_string_literal: true

module Errors
  class Symbolication < ApplicationRecord
    self.table_name = "errors_symbolications"
    belongs_to :project, class_name: "Projects::Project"
    belongs_to :crash_report, class_name: "Crashes::Report", optional: true
    has_many :artifact_references, class_name: "Artifacts::Reference", dependent: :delete_all
  end
end
