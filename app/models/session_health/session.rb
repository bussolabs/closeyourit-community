# frozen_string_literal: true

module SessionHealth
  class Session < ApplicationRecord
    belongs_to :project, class_name: "Projects::Project", inverse_of: :health_sessions
    %i[started_unix_nano update_unix_nano sequence errors_count].each do |name|
      attribute name, ActiveModel::Type::Decimal.new(precision: 20)
    end
  end
end
