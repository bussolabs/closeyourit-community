# frozen_string_literal: true

module Agents
  module LiveEvents
    # The file paths of a project's default branch, read from GitHub, so the live page can show the whole project
    # and light up the files an agent touches. Names only, never contents. Cached per repository; nil without a
    # GitHub repository or when GitHub does not answer, and a failure is never cached.
    class ProjectTree
      MAX_PATHS = 20_000
      TTL = 10.minutes

      Result = Data.define(:paths, :partial) do
        def partial? = partial
      end

      # One directory level at a time, so the page renders only the folders that are open.
      class Index
        # "" for the project root; File.dirname answers "." there.
        def self.parent_of(path) = File.dirname(path).then { it == "." ? "" : it }

        def initialize(paths)
          @levels = Hash.new { |hash, dir| hash[dir] = { folders: Set.new, files: [] } }
          paths.each { add(it) }
        end

        def folders(dir) = @levels.fetch(dir, nil)&.dig(:folders)&.sort || []

        def files(dir) = @levels.fetch(dir, nil)&.dig(:files)&.sort || []

        private

        def add(path)
          parent = self.class.parent_of(path)
          @levels[parent][:files] << path
          until parent.empty?
            above = self.class.parent_of(parent)
            @levels[above][:folders] << parent
            parent = above
          end
        end
      end

      def self.call(project:, client: Github::Client.new) = new(project:, client:).call

      def initialize(project:, client:)
        @repository = project.github_repository
        @client = client
      end

      def call
        return nil if @repository&.default_branch.blank?

        key = "automator_live:tree:#{@repository.id}:#{@repository.default_branch}"
        cached = Rails.cache.read(key)
        return cached if cached

        fetch&.tap { Rails.cache.write(key, it, expires_in: TTL) }
      end

      private

      def fetch
        tree = @client.git_tree(@repository.github_installation_id, @repository.full_name, @repository.default_branch)
        return nil if tree.nil?

        paths = tree[:entries].select { it["type"] == "blob" }.map { it["path"] }.sort
        Result.new(paths: paths.first(MAX_PATHS), partial: tree[:truncated] || paths.size > MAX_PATHS)
      rescue Github::Client::Error
        nil
      end
    end
  end
end
