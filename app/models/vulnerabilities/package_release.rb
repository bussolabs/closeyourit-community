# frozen_string_literal: true

module Vulnerabilities
  # When a package version was published, shared by every project: the date never changes, so it is
  # asked to the registry once (CYRA-1167). Only known dates are stored.
  class PackageRelease < ApplicationRecord
    self.table_name = "vulnerabilities_package_releases"

    # A version younger than this is flagged as too recent; past it the warning cannot apply.
    RECENT_WINDOW = 72.hours

    validates :ecosystem, :name, :version, :released_at, presence: true
    validates :name, uniqueness: { scope: %i[ecosystem version] }
  end
end
