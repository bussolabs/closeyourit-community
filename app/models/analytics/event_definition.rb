# frozen_string_literal: true

module Analytics
  # An event a project declares it sends, with the property names it expects (CYRA-1158). The list
  # documents the site: events outside it are still stored, and show up as undeclared.
  class EventDefinition < ApplicationRecord
    belongs_to :project, class_name: "Projects::Project", inverse_of: :analytics_event_definitions

    normalizes :name, with: ->(v) { v.to_s.strip.slice(0, Ingest::Normalize::NAME_MAX_LENGTH) }

    validates :name, presence: true, uniqueness: { scope: :project_id },
                     exclusion: { in: [ Pageview::PAGEVIEW_NAME ] }
    validate :property_names_within_caps

    scope :ordered, -> { order(:name) }

    # The form sends one comma separated text, the CLI a list: both end up as clean distinct names.
    def property_names=(value)
      list = value.is_a?(Array) ? value : value.to_s.split(",")
      super(list.map { _1.to_s.strip }.compact_blank.uniq)
    end

    private

    def property_names_within_caps
      if property_names.size > Constants::EVENT_PROPERTIES_MAX
        errors.add(:property_names, :too_long, count: Constants::EVENT_PROPERTIES_MAX)
      elsif property_names.any? { _1.length > Constants::EVENT_PROPERTY_NAME_MAX_LENGTH }
        errors.add(:property_names, :invalid)
      end
    end
  end
end
