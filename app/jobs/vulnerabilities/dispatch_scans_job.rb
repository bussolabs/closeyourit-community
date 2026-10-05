# frozen_string_literal: true

module Vulnerabilities
  # Fan-out giornaliero: un job per progetto con un repository collegato.
  #
  # Ogni giorno e non ogni ora perché il lavoro utile è il confronto con advisory nuovi, e OSV
  # pubblica a quel ritmo; più spesso significherebbe rifare la stessa domanda e ottenere la stessa
  # risposta, occupando l'unico thread della corsia `batch` su cui gira la scansione vera. Il fan-out
  # in sé è una query e resta sulla corsia `maintenance` dei controlli.
  class DispatchScansJob < ApplicationJob
    queue_as :maintenance

    def perform
      Projects::Project.joins(:github_repository)
                       .where(github_repositories: { sync_enabled: true })
                       .find_each { |project| Vulnerabilities::ScanProjectJob.perform_later(project.id) }
    end
  end
end
