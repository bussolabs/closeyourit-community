# frozen_string_literal: true

module Agents
  # One published version of the public cyi skills package, the same for every organization
  # (CYRA-912). Rows come from the public GitHub releases (Agents::SkillReleases::Sync) and never change
  # url or sha256 afterwards: the CLI verifies the download against the first value seen.
  class SkillRelease < ApplicationRecord
    VERSION_FORMAT = /\A\d+\.\d+\.\d+\z/

    has_many :pins, class_name: "Agents::SkillReleasePin", inverse_of: :skill_release, dependent: :restrict_with_error

    normalizes :sha256, with: ->(value) { value.to_s.strip.downcase }

    validates :version, presence: true, uniqueness: true, format: { with: VERSION_FORMAT }
    validates :url, presence: true, format: { with: %r{\Ahttps://\S+\z} }
    validates :sha256, presence: true, format: { with: /\A[0-9a-f]{64}\z/ }
    validates :published_at, presence: true

    scope :available, -> { where(withdrawn_at: nil) }

    # Text order puts 1.10.0 before 1.9.0: compare as versions in Ruby (the list stays small).
    def self.latest_available = available.max_by(&:semver)

    def semver = Gem::Version.new(version)

    def withdrawn? = withdrawn_at.present?
  end
end
