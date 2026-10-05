# frozen_string_literal: true

module Artifacts
  class ProguardMap < ApplicationRecord
    belongs_to :project, class_name: "Projects::Project"
    belongs_to :created_by, class_name: "Accounts::Account", optional: true
    belongs_to :blob, class_name: "Artifacts::Blob"
    has_many :references, class_name: "Artifacts::Reference", dependent: :delete_all
  end
end
