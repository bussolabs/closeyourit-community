# frozen_string_literal: true

# The project CHANGELOG.md as structured data (source of truth for the version shown in the UI).
module Changelog
  PATH = Rails.root.join("CHANGELOG.md")

  module_function

  # A deployed image never changes its file: parse once per process instead of reading the parsed
  # blob back from the shared cache on every page (CYRA-889).
  def releases
    sha = ENV["APP_GIT_SHA"]
    return Rails.cache.fetch("changelog:v1:dev") { parse } if sha.blank?

    memo = @memo
    return memo.last if memo&.first == sha

    (@memo = [ sha, parse ].freeze).last
  end

  def parse = Parse.call(File.exist?(PATH) ? File.read(PATH) : "")

  # Le N release più recenti (per il modale in sidebar).
  def recent(count) = releases.first(count)

  # La release corrente (la più recente), o nil se il CHANGELOG è vuoto/assente.
  def current = releases.first
end
