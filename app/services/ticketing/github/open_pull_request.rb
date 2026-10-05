# frozen_string_literal: true

module Ticketing
  module Github
    # Apre una PR GitHub da un ticket: titolo prefissato col codice ticket, body con riferimento al
    # ticket, head = branch del ticket (il più recente, se non passato) verso il base (default branch).
    # Registra l'evento `pull_request_opened`. Repo agganciato richiesto (R404-GITHUB-002); nessun branch
    # del ticket o errore GitHub (es. PR senza diff) → R422-GITHUB-005. Condiviso da Member e CLI.
    class OpenPullRequest < ApplicationService
      def initialize(ticket:, actor:, head: nil, base: nil, true_actor: nil, client: ::Github::Client.new)
        @ticket = ticket
        @actor = actor
        @head = head
        @base = base
        @true_actor = true_actor
        @client = client
      end

      def call
        repository = @ticket.project.github_repository
        return err("R404-GITHUB-002", :not_found, "github.errors.no_repo") if repository.nil?

        head = @head.presence || default_head(repository)
        return err("R422-GITHUB-005", :unprocessable_content, "github.errors.no_branch") if head.blank?

        base = @base.presence || repository.default_branch
        response = @client.create_pull(
          repository.installation.installation_id, repository.full_name,
          title: pr_title, head:, base:, body: I18n.t("github.pull_request_body", code: @ticket.code)
        )

        Result.ok(persist!(repository, response, head, base))
      rescue ::Github::Client::Error => e
        Result.err(AppError.new(e.message, code: "R422-GITHUB-005", status: :unprocessable_content))
      end

      private

      # Branch del ticket più recente (creato da CreateBranch). GitHub rifiuta le PR senza diff → il
      # branch deve avere commit (guida lato UI); qui basta che esista un head.
      def default_head(repository)
        repository.branches.where(ticket: @ticket).order(created_at: :desc).limit(1).pick(:name)
      end

      def pr_title = "#{@ticket.code} #{@ticket.title}"

      def persist!(repository, response, head, base)
        pull = nil
        ApplicationRecord.transaction do
          pull = repository.pull_requests.create!(
            ticket: @ticket, number: response["number"], title: pr_title, state: :open,
            head_ref: head, base_ref: base, html_url: response["html_url"],
            github_id: response["id"], author_login: response.dig("user", "login"),
            # CYRA-600 — il codice che c'è dentro, non solo il nome del ramo che lo indica.
            # Se la risposta non li porta restano vuoti: meglio un buco dichiarato di un valore inventato.
            head_sha: response.dig("head", "sha"), github_updated_at: response["updated_at"]
          )
          RecordActivity.call(ticket: @ticket, actor: @actor, true_actor: @true_actor,
                              action: "pull_request_opened", data: { number: response["number"] })
        end
        pull
      end

      def err(code, status, key)
        Result.err(AppError.new(I18n.t(key), code:, status:))
      end
    end
  end
end
