# frozen_string_literal: true

module Knowledge
  # Backfill one-shot: crea la versione 1 per le pagine KB preesistenti senza cronologia (coda
  # :batch). Lo snapshot rispecchia il contenuto corrente; created_at = updated_at della
  # pagina (miglior stima del momento dell'ultima modifica). Idempotente: salta le pagine che
  # hanno già almeno una versione. Lancio manuale al deploy:
  #   bin/rails runner 'Knowledge::BackfillVersionsJob.perform_later'
  # NON va in recurring.yml: è un'operazione di bootstrap/migrazione, non un cron.
  class BackfillVersionsJob < ApplicationJob
    queue_as :batch

    def perform
      Knowledge::Page.where.missing(:versions).find_each do |page|
        Knowledge::Version.create!(
          page: page,
          organization_id: page.organization_id,
          number: 1,
          title: page.title,
          body: page.body,
          kind: page.kind,
          created_by: page.created_by,
          author_name: page.created_by&.name,
          created_at: page.updated_at
        )
      end
    end
  end
end
