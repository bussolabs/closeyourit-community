# frozen_string_literal: true

module Wikitech
  # The canonical form of a GitHub repository address, the key cards merge on:
  # `https://github.com/<owner>/<repo>`, lowercase, without `.git` or deeper paths.
  module RepoUrl
    PATTERN = %r{\Ahttps?://(?:www\.)?github\.com/([A-Za-z0-9][A-Za-z0-9-]*)/([A-Za-z0-9._-]+)}i
    # First path segments that are GitHub pages, not repository owners.
    RESERVED_OWNERS = %w[about collections explore features login marketplace orgs settings sponsors topics trending].freeze

    module_function

    def normalize(url)
      match = PATTERN.match(url.to_s.strip)
      return nil if match.nil?

      owner = match[1].downcase
      repo = match[2].delete_suffix(".git").downcase
      return nil if RESERVED_OWNERS.include?(owner) || repo.blank? || repo.start_with?(".")

      "https://github.com/#{owner}/#{repo}"
    end

    def full_name(repo_url) = repo_url.to_s.delete_prefix("https://github.com/")
  end
end
