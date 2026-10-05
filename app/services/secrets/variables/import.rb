# frozen_string_literal: true

module Secrets
  module Variables
    # Import bulk (all-or-nothing) di più variabili per [progetto, ambiente]. Usato da
    # `cyi secrets import`/.env. Se anche una sola voce è invalida, l'intero import fa rollback e il
    # primo errore torna nel Result (nessuna scrittura parziale).
    #
    # CYRA-230: ogni voce passa per Secrets::ChangeRequests::Submit invece di Set diretto — così anche il
    # canale CLI rispetta l'approvazione a due. Su un ambiente PROTETTO ogni voce diventa una change
    # request pending (nulla è scritto); su un ambiente non protetto il comportamento resta IDENTICO a
    # prima (tutto applicato, UN solo evento "imported" + UN solo sync). Submit è chiamato con
    # enqueue_sync/audit false: l'evento aggregato e il sync li fa QUI, una volta, dopo il commit.
    class Import < ApplicationService
      include Secrets::Github::Syncable

      # submissions: una Secrets::ChangeRequests::Submit::Submitted per voce (applicata subito o accodata
      # in attesa). #applied_count/#pending_count distinguono i due esiti per il controller (201 importato
      # vs 202 in attesa). Gemello di Secrets::Rows::Save::Outcome (là 1 nome × N ambienti, qui 1 ambiente
      # × N nomi).
      Outcome = Data.define(:submissions) do
        def applied = submissions.select(&:applied?)
        def pending = submissions.select(&:pending?)
        def applied_count = applied.size
        def pending_count = pending.size
      end

      # entries: array di hash { name:, value:, description? }
      def initialize(project:, environment:, entries:, actor: nil)
        @project = project
        @environment = environment
        @entries = entries
        @actor = actor
      end

      def call
        return Result.ok(Outcome.new(submissions: [])) if @entries.blank?

        submissions = []
        failure = nil

        ActiveRecord::Base.transaction do
          @entries.each do |entry|
            result = ::Secrets::ChangeRequests::Submit.call(
              project: @project, environment: @environment, action: :set,
              name: entry[:name], value: entry[:value], description: entry[:description],
              actor: @actor, enqueue_sync: false, audit: false
            )

            if result.err?
              failure = result.error
              raise ActiveRecord::Rollback
            end

            submissions << result.value
          end
        end

        return Result.err(failure) if failure

        # UN solo enqueue + UN solo evento audit "imported" dopo il commit, e SOLO se qualcosa è stato
        # davvero applicato: su un ambiente protetto ogni voce è una change request pending — niente da
        # sincronizzare né da registrare finché non è approvata (come Secrets::Rows::Save).
        applied = submissions.select(&:applied?)
        if applied.any?
          enqueue_github_sync(@project)
          ::Secrets::RecordEvent.call(action: "imported", project: @project, environment: @environment,
                                      actor: @actor, metadata: { count: applied.size })
        end

        Result.ok(Outcome.new(submissions:))
      end
    end
  end
end
