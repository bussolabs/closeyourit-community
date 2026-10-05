# frozen_string_literal: true

module Secrets
  module Shared
    module Rows
      # Salva una "riga" della matrice shared secret: upsert di N celle (un ambiente ciascuna) per UNO
      # stesso nome. Gemello di Secrets::Rows::Save (secret di progetto), con in più la conferma
      # d'impatto AGGREGATA sulle rotazioni di valori delegati. Le celle con valore blank sono SALTATE
      # (svuotare non cancella; il delete è esplicito per cella). All-or-nothing: una cella invalida fa
      # rollback dell'intera riga. Usato dalla riga di creazione e dal salvataggio-riga della pagina.
      class Save < ApplicationService
        include ::Secrets::Github::Syncable

        # cells: array di hash { environment:, value: }
        def initialize(organization:, name:, cells:, actor: nil, confirmation_digest: nil)
          @organization = organization
          @name = name.to_s.strip.upcase
          @cells = cells
          @actor = actor
          @confirmation_digest = confirmation_digest
        end

        def call
          present_cells = @cells.reject { |cell| cell[:value].to_s.blank? }
          if present_cells.empty?
            message = I18n.t("member.review_fixes.secret_value_required")
            return Result.err(AppError.new(message, code: "R422-SHARED-001", status: :unprocessable_content,
                                           details: { base: [ message ] }))
          end

          targets = confirmation_targets(present_cells)
          if targets.any?
            impact = RowImpact.call(shared_values: targets).value
            unless ActiveSupport::SecurityUtils.secure_compare(@confirmation_digest.to_s, impact["digest"])
              return Result.err(AppError.new("Conferma richiesta", code: "R409-SHARED-001", details: impact))
            end
          end

          saved = []
          failure = nil
          ApplicationRecord.transaction do
            present_cells.each do |cell|
              result = ::Secrets::Shared::Save.call(
                organization: @organization, name: @name, environment: cell[:environment],
                value: cell[:value], actor: @actor, skip_confirmation: true, enqueue_sync: false
              )
              if result.err?
                failure = result.error
                raise ActiveRecord::Rollback
              end
              saved << result.value
            end
          end
          return Result.err(failure) if failure

          enqueue_row_sync(saved)
          Result.ok(saved)
        end

        private

        # Celle che cambiano valore E hanno già deleghe attive → richiedono la conferma d'impatto.
        # Una cella nuova (nessun valore esistente sull'ambiente) non ha deleghe → nessuna conferma.
        def confirmation_targets(cells)
          variable = @organization.shared_secret_variables.find_by(name: @name)
          return [] unless variable

          cells.filter_map do |cell|
            value_record = variable.values.find_by(environment: cell[:environment])
            next unless value_record
            next if value_record.value == cell[:value].to_s

            value_record if value_record.delegations.exists?
          end
        end

        # UN solo enqueue del sync GitHub dopo il commit (Save chiamato con enqueue_sync: false → niente
        # enqueue orfano se una cella successiva fa rollback).
        def enqueue_row_sync(saved)
          saved.flat_map { |value| value.projects.to_a }.uniq.each { |project| enqueue_github_sync(project) }
        end
      end
    end
  end
end
