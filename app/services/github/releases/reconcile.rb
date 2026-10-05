# frozen_string_literal: true

module Github
  module Releases
    # Binding tag→release: marca la release [progetto, version, environment] come `current` (live)
    # quando convergono i due segnali — il deploy CI (che crea la riga release) e il tag GitHub (che
    # ne conferma la stabilità). Chiamato da due punti (idempotente):
    #   - Api::V1::ReleasesController#create (environment = quello del token di deploy);
    #   - Github::Webhooks::{Push,Create} su un tag (environment = quello mappato dalla stabilità).
    # Procede solo se il progetto ha un repo agganciato con tag_binding_enabled E la stabilità del tag
    # mappa PROPRIO su questo environment (tag stabile→production, pre-release→staging, dalle regole del
    # progetto). Nessuna release presente ⇒ no-op: l'altro trigger completa il binding alla convergenza.
    class Reconcile < ApplicationService
      def initialize(project:, version:, environment:, git_tag_url: nil)
        @project = project
        @version = version.to_s.strip
        @environment = environment.to_s.strip.downcase
        @git_tag_url = git_tag_url.presence
      end

      def call
        return Result.ok(nil) if @version.blank? || @environment.blank?

        repository = @project.github_repository
        return Result.ok(nil) unless repository&.tag_binding_enabled?

        target = repository.target_environment_code(stable: Github::Version.stable?(@version))
        return Result.ok(nil) if target.blank? || target != @environment

        release = @project.releases.find_by(version: @version, environment: @environment)
        return Result.ok(nil) if release.nil?

        mark_current!(release)
        Result.ok(release)
      end

      private

      # Al più una release `current` per [progetto, environment] (indice parziale unico): azzera la
      # precedente e marca questa, in transazione. deployed_at fissato solo alla prima conferma.
      def mark_current!(release)
        Projects::Release.transaction do
          @project.releases
                  .where(environment: @environment, current: true)
                  .where.not(id: release.id)
                  .update_all(current: false)

          attributes = { current: true }
          attributes[:deployed_at] = Time.current unless release.current?
          attributes[:git_tag_url] = @git_tag_url if @git_tag_url
          release.update!(attributes)
        end
      end
    end
  end
end
