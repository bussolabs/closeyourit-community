# frozen_string_literal: true

module Artifacts
  class Reference < ApplicationRecord
    belongs_to :project, class_name: "Projects::Project"
    belongs_to :source_map, class_name: "Artifacts::SourceMap", optional: true
    belongs_to :native_symbol, class_name: "Artifacts::NativeSymbol", optional: true
    belongs_to :proguard_map, class_name: "Artifacts::ProguardMap", optional: true
    belongs_to :symbolication, class_name: "Errors::Symbolication"
  end
end
