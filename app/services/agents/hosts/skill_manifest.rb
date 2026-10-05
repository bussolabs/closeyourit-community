# frozen_string_literal: true

module Agents
  module Hosts
    # Bundle skill versionato pinnato per l'organizzazione, servito all'Agent Host per clonare il plugin
    # `closeyourit-skills` ed eseguirlo in skill-mode. Gemello di WorkspaceManifest, con due differenze di
    # contratto: `version` è il NOME DIRECTORY del plugin (non lo schema-version 1) e `digest` è lo SHA del
    # commit atteso passato PER RIFERIMENTO (la verifica content-addressed la fa il client dopo il clone),
    # non un hash calcolato qui. Nessun bundle pinnato → err 404 (l'host resta in prompt-mode: additivo).
    class SkillManifest < ApplicationService
      def initialize(organization:)
        @organization = organization
      end

      def call
        bundle = @organization.skill_bundle
        if bundle.nil?
          return Result.err(AppError.new(
            "Nessuno skill bundle pinnato per l'organizzazione",
            code: "R404-AGENT-004", status: :not_found
          ))
        end

        Result.ok(
          version: bundle.version,
          digest: bundle.digest,
          repo: bundle.repo,
          ref: bundle.ref
        )
      end
    end
  end
end
