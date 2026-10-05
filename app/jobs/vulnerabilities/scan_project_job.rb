# frozen_string_literal: true

module Vulnerabilities
  # Scansione di UN progetto. `limits_concurrency` per la stessa ragione di Uptime::CheckJob: una
  # scansione lenta (un monorepo con molti lockfile) non deve incrociarsi con quella successiva —
  # due esecuzioni sovrapposte si contendono gli stessi manifest e sprecano richieste a OSV.
  class ScanProjectJob < ApplicationJob
    queue_as :batch
    limits_concurrency to: 1, key: ->(project_id) { "vulnerabilities:scan:#{project_id}" }

    def perform(project_id)
      project = Projects::Project.find_by(id: project_id)
      # Progetto cancellato fra il fan-out e l'esecuzione: no-op, come fanno gli altri worker.
      return if project.nil?

      Vulnerabilities::ScanProject.call(project: project)
    end
  end
end
