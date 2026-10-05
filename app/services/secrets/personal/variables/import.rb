# frozen_string_literal: true

module Secrets
  module Personal
    module Variables
      # Import bulk (all-or-nothing) di più variabili per [account, organization]. Usato da
      # `cyi personal import`/.env. Se anche una sola voce è invalida, l'intero import fa rollback e il
      # primo errore torna nel Result (nessuna scrittura parziale, nessun evento).
      class Import < ApplicationService
        # entries: array di hash { name:, value:, description? }
        def initialize(account:, organization:, entries:)
          @account = account
          @organization = organization
          @entries = entries
        end

        def call
          return Result.ok([]) if @entries.blank?

          imported = []
          failure = nil

          ActiveRecord::Base.transaction do
            @entries.each do |entry|
              result = Set.call(
                account: @account, organization: @organization,
                name: entry[:name], value: entry[:value], description: entry[:description],
                audit: false
              )

              if result.err?
                failure = result.error
                raise ActiveRecord::Rollback
              end

              imported << result.value
            end
          end

          return Result.err(failure) if failure

          # UN solo evento audit "imported" dopo il commit (Set con audit: false → niente N eventi "set").
          Secrets::Personal::RecordEvent.call(action: "imported", account: @account,
                                              organization: @organization, metadata: { count: imported.size })
          Result.ok(imported)
        end
      end
    end
  end
end
