# frozen_string_literal: true

module Github
  module Manifests
    # Allinea i lockfile noti di un progetto a quelli presenti nel suo repository (CYRA-506).
    #
    # Scoprirli dall'albero, invece di cercarli nei path canonici, è l'unico modo che regge un
    # monorepo: `apps/api/Gemfile.lock` e `apps/web/pnpm-lock.yaml` sono normali quanto un lockfile
    # in radice, e nessuna convenzione dice dove stiano.
    #
    # Chiude il ciclo in entrambi i sensi: i lockfile nuovi entrano, quelli spariti dal repository
    # escono — con i loro pacchetti e le loro vulnerabilità, che non descrivono più niente.
    class Discover < ApplicationService
      # `tree` opzionale: chi ha già scaricato l'albero (la scansione, che lo usa anche per i file dei
      # runtime) lo passa invece di far ripetere la richiesta.
      def initialize(project:, client: Github::Client.new, tree: :fetch)
        @project = project
        @client = client
        @tree = tree
      end

      def call
        repository = @project.github_repository
        return Result.err(no_repository_error) if repository.nil?

        tree = @tree == :fetch ? fetch_tree(repository) : @tree
        # Repository vuoto o branch che non esiste ancora: è uno stato normale di un progetto appena
        # collegato, non un guasto. Non tocchiamo nulla — cancellare i manifest noti per un 404
        # temporaneo cancellerebbe anche lo storico dei finding.
        return Result.ok([]) if tree.nil?

        Result.ok(sync(discovered(tree)))
      rescue Github::Client::Error => e
        Result.err(AppError.new(e.message, code: e.code, status: e.status))
      end

      private

      def fetch_tree(repository)
        @client.git_tree(repository.installation.installation_id, repository.full_name,
                         repository.default_branch)
      end

      def discovered(tree)
        entries = tree[:entries].select do |entry|
          entry["type"] == "blob" && Vulnerabilities::Ecosystem.scannable?(entry["path"])
        end

        # Un albero troncato dall'API o un monorepo patologico non devono trasformare una scansione
        # in una maratona: si prende un tetto e lo si dichiara nel log, invece di sembrare completi.
        limit = Vulnerabilities::Constants::MAX_MANIFESTS_PER_PROJECT
        if entries.size > limit
          Rails.logger.warn(
            "[vulnerabilities] #{@project.key}: #{entries.size} manifest trovati, ne scansiono #{limit}"
          )
          entries = entries.sort_by { |entry| entry["path"].count("/") }.first(limit)
        end

        entries
      end

      def sync(entries)
        paths = entries.map { |entry| entry["path"] }
        @project.vulnerability_manifests.where.not(path: paths).destroy_all

        entries.map do |entry|
          manifest = @project.vulnerability_manifests.find_or_initialize_by(path: entry["path"])
          manifest.ecosystem = Vulnerabilities::Ecosystem.for_path(entry["path"])
          manifest.blob_sha = entry["sha"]
          manifest.save!
          manifest
        end
      end

      def no_repository_error
        AppError.new("Il progetto non ha un repository GitHub collegato",
                     code: "R422-VULN-002", status: :unprocessable_content)
      end
    end
  end
end
