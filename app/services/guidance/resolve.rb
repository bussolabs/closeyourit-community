# frozen_string_literal: true

module Guidance
  # Fonte UNICA di ereditarietà e override della guidance (CYRA-74). Dato un progetto compone la catena
  # organizzazione → gruppo (se presente) → progetto e restituisce references e procedures APPLICABILI,
  # ciascuna con la sua origine (`level`). È un service di sola composizione read-only: non muta nulla e
  # non fallisce, quindi ritorna direttamente la struct (come Authorization::AccessMatrix), non un Result.
  #
  # Regole di risoluzione, per `key`, scorrendo i livelli dal più lontano (org) al più vicino (progetto):
  # - key distinte si accumulano (append/inherit); una key definita solo in alto fluisce al progetto;
  # - REFERENCE: il livello più vicino con `enabled: true` VINCE (replace); un `enabled: false` DISABILITA
  #   la key (né lui né gli antenati compaiono);
  # - PROCEDURE: `application_mode` = inherit | replace | disable; con inherit, `merge_strategy` = override
  #   (tiene il content del più vicino) | append (accoda il più vicino all'ereditato); `enabled: false`
  #   equivale a disable. `replace` taglia la catena di merge e vince da solo.
  # Il risultato non ha mai duplicati per key ed è ordinato per position poi key (deterministico).
  class Resolve < ApplicationService
    ResolvedReference = Data.define(:key, :kind, :location, :instructions, :required, :position, :level)
    ResolvedProcedure = Data.define(:key, :content, :application_mode, :merge_strategy, :position, :level)
    Resolution = Data.define(:references, :procedures)

    # org=0, gruppo=1, progetto=2: la scansione applica sempre "il più vicino vince".
    LEVEL_ORDER = { "organization" => 0, "group" => 1, "project" => 2 }.freeze

    def initialize(project:)
      @project = project
    end

    def call
      Resolution.new(references: resolved_references, procedures: resolved_procedures)
    end

    private

    attr_reader :project

    # Owner della catena, dal più lontano al più vicino. Il gruppo è opzionale (compact lo salta).
    def owners
      @owners ||= [ project.organization, project.group, project ].compact
    end

    def level_of(record)
      Guidance::LEVEL_BY_OWNER_TYPE.fetch(record.owner_type)
    end

    # Record di una stessa key riordinati per livello gerarchico, così la scansione va org → gruppo → progetto.
    def ordered_by_level(records)
      records.sort_by { |record| LEVEL_ORDER.fetch(level_of(record)) }
    end

    def resolved_references
      by_key = Guidance::Reference.where(owner: owners).group_by(&:key)
      sort(by_key.filter_map { |_key, records| resolve_reference(records) })
    end

    # Nearest-wins con disable: l'ultimo livello con enabled: true vince; enabled: false azzera la key.
    def resolve_reference(records)
      winner = nil
      ordered_by_level(records).each { |record| winner = record.enabled? ? record : nil }
      return if winner.nil?

      ResolvedReference.new(key: winner.key, kind: winner.kind, location: winner.location,
                            instructions: winner.instructions, required: winner.required,
                            position: winner.position, level: level_of(winner))
    end

    def resolved_procedures
      by_key = Guidance::Procedure.where(owner: owners).group_by(&:key)
      sort(by_key.filter_map { |_key, records| resolve_procedure(records) })
    end

    # Compone il content secondo application_mode/merge_strategy scorrendo i livelli (vedi commento di classe).
    def resolve_procedure(records)
      content = nil
      winner = nil
      ordered_by_level(records).each do |record|
        if !record.enabled? || record.application_disable?
          content = nil
          winner = nil
        elsif record.application_replace?
          content = record.content
          winner = record
        else # inherit
          content = record.merge_append? && content.present? ? "#{content}\n\n#{record.content}" : record.content
          winner = record
        end
      end
      # winner presente ⇒ content presente (il modello valida content: presence).
      return if winner.nil?

      ResolvedProcedure.new(key: winner.key, content: content, application_mode: winner.application_mode,
                            merge_strategy: winner.merge_strategy, position: winner.position,
                            level: level_of(winner))
    end

    def sort(resolved)
      resolved.sort_by { |item| [ item.position, item.key ] }
    end
  end
end
