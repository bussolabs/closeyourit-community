# frozen_string_literal: true

module Analytics
  module Links
    # Crea un link pubblico di condivisione/embed per un progetto (password opzionale).
    class Create < ApplicationService
      def initialize(project:, password: nil, actor: nil)
        @project = project
        @password = password
        @actor = actor
      end

      def call
        # CYRA-697 — l'autore viaggia col link: pubblicare la dashboard porta dati fuori dal
        # perimetro dell'organizzazione, e finora la domanda «chi è stato» non aveva risposta.
        link = @project.analytics_links.new(enabled: true, created_by: @actor)
        link.password = @password if @password.present?
        saved = @project.with_lock do
          if link.save
            @project.analytics_links.active.where.not(id: link.id).destroy_all
            true
          end
        end
        return Result.ok(link) if saved

        Result.err(AppError.new(
          link.errors.full_messages.to_sentence.presence || "Link non valido",
          code: "R422-LINK-001", details: link.errors.as_json
        ))
      end
    end
  end
end
