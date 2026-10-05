# frozen_string_literal: true

module Ticketing
  module Github
    # Crea un branch GitHub da un ticket: nome prefissato col codice ticket (`KEY-N-slug`) a partire dal
    # base (default branch del repo). Registra l'evento `branch_created` in timeline. Il repo dev'essere
    # agganciato (R404-GITHUB-002). Errori GitHub / branch già esistente → R422-GITHUB-005. Condiviso da
    # Member e CLI. Il `client` è iniettabile (test).
    class CreateBranch < ApplicationService
      def initialize(ticket:, actor:, base: nil, true_actor: nil, client: ::Github::Client.new)
        @ticket = ticket
        @actor = actor
        @base = base
        @true_actor = true_actor
        @client = client
      end

      def call
        repository = @ticket.project.github_repository
        return err("R404-GITHUB-002", :not_found, "github.errors.no_repo") if repository.nil?

        branch_name = build_branch_name
        return err("R422-GITHUB-005", :unprocessable_content, "github.errors.branch_exists") if repository.branches.exists?(name: branch_name)

        base = @base.presence || repository.default_branch
        installation_id = repository.installation.installation_id

        sha = @client.ref(installation_id, repository.full_name, "heads/#{base}").dig("object", "sha")
        @client.create_ref(installation_id, repository.full_name, "refs/heads/#{branch_name}", sha)

        Result.ok(persist!(repository, branch_name))
      rescue ::Github::Client::Error => e
        Result.err(AppError.new(e.message, code: "R422-GITHUB-005", status: :unprocessable_content))
      end

      private

      # Nome = codice ticket (KEY-N, resta uppercase) + slug del titolo. Il match webhook è case-insensitive.
      def build_branch_name
        slug = @ticket.title.to_s.parameterize.first(50).delete_suffix("-")
        [ @ticket.code, slug.presence ].compact.join("-")
      end

      def persist!(repository, branch_name)
        branch = nil
        ApplicationRecord.transaction do
          branch = repository.branches.create!(
            ticket: @ticket, name: branch_name,
            html_url: "https://github.com/#{repository.full_name}/tree/#{branch_name}"
          )
          RecordActivity.call(ticket: @ticket, actor: @actor, true_actor: @true_actor,
                              action: "branch_created", data: { branch: branch_name })
        end
        branch
      end

      def err(code, status, key)
        Result.err(AppError.new(I18n.t(key), code:, status:))
      end
    end
  end
end
