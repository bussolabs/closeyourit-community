# frozen_string_literal: true

module Secrets
  module Rows
    # Salva una "riga" della matrice secret: upsert di N celle (un ambiente ciascuna) per UNO stesso
    # nome. Speculare a `Secrets::Variables::Import` (1 ambiente × N nomi) ma per la vista a matrice
    # (1 nome × N ambienti). All-or-nothing SOLO per gli errori reali: se una cella è invalida (es. nome
    # non conforme, prefisso GITHUB_), l'intera riga fa rollback e il primo errore torna nel Result —
    # nessuna scrittura parziale. Costo: N celle scritte = N snapshot di versione (uno per
    # secret_variable_id): query per-record indipendenti (non un N+1 di caricamento), lineari e attese
    # per un'azione a bassa frequenza.
    #
    # CYRA-138, Fase 4 pezzo C1b: ogni cella passa per Secrets::ChangeRequests::Submit invece di Set
    # diretto. Su un ambiente PROTETTO (Secrets::Approval) la cella diventa una ChangeRequest pending
    # invece di essere scritta subito; sulle celle di ambienti non protetti il comportamento resta
    # IDENTICO a oggi (opt-in OFF di default → sempre applicato, mai una CR). Una richiesta pending è un
    # record valido, NON un errore: non innesca il rollback della riga.
    class Save < ApplicationService
      include Secrets::Github::Syncable

      # submissions: una Secrets::ChangeRequests::Submit::Submitted per cella scritta (applicata o
      # accodata in attesa). #applied_count/#pending_count alimentano il notice aggregato del controller
      # ("N salvate, M in attesa di approvazione").
      Outcome = Data.define(:submissions) do
        def applied_count = submissions.count(&:applied?)
        def pending_count = submissions.count(&:pending?)
      end

      # Blank values preserve existing secrets; descriptions may still be updated.
      def initialize(project:, name:, cells:, actor: nil)
        @project = project
        @name = name
        @cells = cells
        @actor = actor
      end

      def call
        return row_error("secret_protected_description") if @cells.any? { |cell| protected_description_change?(cell) }

        submissions = []
        failure = nil

        ActiveRecord::Base.transaction do
          @cells.each do |cell|
            submission = submitted_attributes(cell)
            next unless submission

            result = ::Secrets::ChangeRequests::Submit.call(
              project: @project, environment: cell[:environment], action: :set,
              name: @name, **submission, description: cell[:description],
              actor: @actor, enqueue_sync: false
            )

            if result.err?
              failure = result.error
              raise ActiveRecord::Rollback
            end

            submissions << result.value
          end
        end

        return Result.err(failure) if failure
        return row_error("secret_no_changes") if submissions.empty?

        # UN solo enqueue dopo il commit (Submit chiamato con enqueue_sync: false per la parte applicata
        # subito), e solo se almeno una cella è stata scritta davvero: una riga interamente in attesa non
        # tocca il bundle GitHub, non c'è nulla da sincronizzare finché la richiesta non è approvata (C2).
        enqueue_github_sync(@project) if submissions.any?(&:applied?)
        Result.ok(Outcome.new(submissions:))
      end

      private

      # Approval requests cannot persist descriptions with the current schema.
      def protected_description_change?(cell)
        return false if ::Secrets::ChangeRequest.description_requests_supported?
        return false if cell[:description].nil?
        return false unless ::Secrets::Approval.required?(project: @project, environment: cell[:environment])

        variable = existing_variable(cell)
        return false if variable.nil? && cell[:value].to_s.blank?

        variable&.description.to_s != cell[:description].to_s.strip
      end

      def existing_variable(cell)
        @project.secret_variables.find_by(environment: cell[:environment], name: @name.to_s.strip.upcase)
      end

      # A description-only edit preserves the value and its rotation history.
      def submitted_attributes(cell)
        return { value: cell[:value] } if cell[:value].to_s.present?
        return if cell[:description].nil?

        variable = existing_variable(cell)
        return unless variable && variable.description.to_s != cell[:description].to_s.strip

        { description_only: true }
      end

      def row_error(key)
        message = I18n.t("member.review_fixes.#{key}")
        Result.err(AppError.new(message, code: "R422-SECRET-001", status: :unprocessable_content,
                                details: { base: [ message ] }))
      end
    end
  end
end
