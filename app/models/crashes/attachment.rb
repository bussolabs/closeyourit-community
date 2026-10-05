# frozen_string_literal: true

module Crashes
  class Attachment < ApplicationRecord
    belongs_to :project, class_name: "Projects::Project"
    belongs_to :report, class_name: "Crashes::Report", inverse_of: :attachments
    belongs_to :blob, class_name: "Crashes::Blob", inverse_of: :attachment
    validates :kind, inclusion: { in: %w[text report] }
  end
end
