# frozen_string_literal: true

module Guidance
  # Preview del contesto EFFETTIVO di un progetto per la UI member (CYRA-75). Guidance::Resolve resta la
  # fonte UNICA del risolto (ciò che riceve la CLI); Preview lo affianca annotando, per ogni key coinvolta
  # ai tre livelli, il suo STATO rispetto al progetto e la sua ORIGINE (DoD: "origine e override espliciti"):
  # - here       → definita solo al progetto;
  # - inherited  → attiva ma definita più in alto (org o gruppo), non ridefinita qui;
  # - overridden → attiva al progetto E presente anche in un antenato (sostituisce/compone l'ereditata);
  # - disabled   → presente in catena ma soppressa (enabled: false / procedure disable) → fuori dal risolto.
  # Read-only e non fallisce, come Resolve: ritorna direttamente la struct.
  class Preview < ApplicationService
    ReferenceRow = Data.define(:key, :status, :origin, :kind, :location, :instructions, :required, :position)
    ProcedureRow = Data.define(:key, :status, :origin, :content, :application_mode, :merge_strategy, :position)
    Result = Data.define(:references, :procedures)

    # org=0, gruppo=1, progetto=2: il livello più vicino al progetto è quello con l'ordine più alto.
    LEVEL_ORDER = { "organization" => 0, "group" => 1, "project" => 2 }.freeze

    def initialize(project:)
      @project = project
    end

    def call
      Result.new(references: reference_rows, procedures: procedure_rows)
    end

    private

    attr_reader :project

    # Stessa catena di Guidance::Resolve, dal più lontano al più vicino (il gruppo è opzionale).
    def owners
      @owners ||= [ project.organization, project.group, project ].compact
    end

    def level_of(record) = Guidance::LEVEL_BY_OWNER_TYPE.fetch(record.owner_type)

    # Il risolto (attivi con la loro origine) viene da Resolve: unica fonte del contesto CLI.
    def resolution
      @resolution ||= Guidance::Resolve.call(project:)
    end

    def reference_rows
      active = resolution.references.index_by(&:key)
      rows = Guidance::Reference.where(owner: owners).group_by(&:key).map do |key, records|
        status, origin, source = classify(records, active[key])
        ReferenceRow.new(key:, status:, origin:, kind: source.kind, location: source.location,
                         instructions: source.instructions, required: source.required, position: source.position)
      end
      sort_rows(rows)
    end

    def procedure_rows
      active = resolution.procedures.index_by(&:key)
      rows = Guidance::Procedure.where(owner: owners).group_by(&:key).map do |key, records|
        status, origin, source = classify(records, active[key])
        ProcedureRow.new(key:, status:, origin:, content: source.content, application_mode: source.application_mode,
                         merge_strategy: source.merge_strategy, position: source.position)
      end
      sort_rows(rows)
    end

    # Data la lista di record grezzi di UNA key e l'eventuale elemento risolto (attivo), decide stato,
    # origine e la fonte dei valori da mostrare (il risolto se attivo, altrimenti il record più vicino che
    # è stato soppresso). `active` è una struct di Resolve (porta già il `level`); i record sono AR.
    def classify(records, active)
      levels = records.map { |record| level_of(record) }
      if active
        if active.level == "project"
          [ local_status(active, levels), "project", active ]
        else
          [ :inherited, active.level, active ]
        end
      else
        nearest = records.max_by { |record| LEVEL_ORDER.fetch(level_of(record)) }
        [ :disabled, level_of(nearest), nearest ]
      end
    end

    # A livello progetto: `here` se non c'è un antenato con la key; se c'è, la procedura che ACCODA
    # l'ereditata (inherit+append) è `appended` (compone, non sostituisce), le altre `overridden`.
    def local_status(active, levels)
      return :here unless levels.any? { |l| l != "project" }

      appended?(active) ? :appended : :overridden
    end

    def appended?(active)
      active.respond_to?(:merge_strategy) &&
        active.application_mode.to_s == "inherit" && active.merge_strategy.to_s == "append"
    end

    def sort_rows(rows)
      rows.sort_by { |row| [ row.position, row.key ] }
    end
  end
end
