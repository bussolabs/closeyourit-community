# frozen_string_literal: true

require "zlib"

module OrganizationsHelper
  # A fixed color per organization, so people in several of them see where they are (CYRA-898).
  # Literal classes: Tailwind only ships the classes it can read in the source.
  SWATCHES = %w[
    bg-indigo-500 bg-teal-500 bg-amber-500 bg-rose-500
    bg-sky-500 bg-violet-500 bg-emerald-500 bg-orange-500
  ].freeze

  def organization_swatch_class(organization)
    SWATCHES[Zlib.crc32(organization.id.to_s) % SWATCHES.size]
  end
end
