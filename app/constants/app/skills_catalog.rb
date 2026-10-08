# frozen_string_literal: true

module App
  # Where the public cyi skills package is released (CYRA-912). Every install, self-hosted ones
  # included, reads the same public releases; a mirror can stand in for GitHub.
  module SkillsCatalog
    module_function

    REPO = "bussolabs/cyi-skills"

    def releases_api = ENV["CLOSEYOURIT_SKILLS_RELEASES_API"].presence || "https://api.github.com/repos/#{REPO}"
  end
end
