# frozen_string_literal: true

module Github
  module Repositories
    # Aggancia un repo GitHub a un progetto (1:1). Il repo dev'essere accessibile dall'installazione
    # dell'org. Errori: R404-GITHUB-004 (org senza installazione), R409-GITHUB-003 (progetto già
    # agganciato o repo già usato da un altro progetto), R422-GITHUB-001 (validazione). Condiviso da
    # Member e CLI (rules/backend-channels.md).
    class Connect < ApplicationService
      def initialize(project:, repo_id:, full_name:, default_branch: "main")
        @project = project
        @repo_id = repo_id
        @full_name = full_name
        @default_branch = default_branch.presence || "main"
      end

      def call
        installation = @project.organization.github_installation
        return err("R404-GITHUB-004", :not_found, "github.errors.no_installation") if installation.nil?

        return err("R409-GITHUB-003", :conflict, "github.errors.project_taken") if @project.github_repository.present?
        return err("R409-GITHUB-003", :conflict, "github.errors.repo_taken") if repo_taken?(installation)

        repository = @project.build_github_repository(
          installation:, repo_id: @repo_id, full_name: @full_name, default_branch: @default_branch
        )
        return Result.ok(repository) if repository.save

        Result.err(AppError.new(repository.errors.full_messages.to_sentence,
                                code: "R422-GITHUB-001", details: repository.errors.to_hash))
      end

      private

      def repo_taken?(installation)
        ::Github::Repository.exists?(installation:, repo_id: @repo_id)
      end

      def err(code, status, key)
        Result.err(AppError.new(I18n.t(key), code:, status:))
      end
    end
  end
end
