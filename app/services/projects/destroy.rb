# frozen_string_literal: true

module Projects
  # Cancella un progetto mantenendo l'ordine condiviso con il gate dispatch:
  # policy project-scoped → project. La FK può così eliminare le policy senza invertire
  # il lock policy → project già detenuto da Agents::Limits::Reserve.
  class Destroy < ApplicationService
    def initialize(project:)
      @project = project
    end

    def call
      ApplicationRecord.transaction do
        Agents::LimitPolicy.where(project: @project).order(:id).lock.load
        @project.lock!
        @project.destroy!
      end
      Result.ok(true)
    end
  end
end
