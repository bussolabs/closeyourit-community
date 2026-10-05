# frozen_string_literal: true

module Projects
  # Righe della card "Monitoring tools" della pagina progetto: i tool sono assunti AUTOMATICAMENTE dalle
  # chiamate ricevute (Projects::Source, dall'ingest) + l'agent server derivato (host linkati) — dal
  # CYRA-64 non esiste più la dichiarazione manuale. Ogni riga è una fonte osservata con l'ultima versione
  # vista e lo stato temporale:
  #   :ok       verde — vista di recente (entro SOURCE_FRESH_WITHIN)
  #   :stale    ambra — vista, ma silente da un po' (entro SOURCE_STALE_WITHIN)
  #   :missing  rosso — silente oltre SOURCE_STALE_WITHIN (verosimilmente dismessa)
  # N+1-safe: precarica sources, server_links(:host).
  class ToolsOverview
    # Fonte osservata unificata (una Projects::Source o l'agent derivato dagli host linkati). `source_id`
    # = id della Projects::Source per il link "Cronologia" (nil sull'agent derivato, che non ha una riga).
    Observed = Data.define(:tool_code, :version, :last_seen_at, :source_id)

    Row = Data.define(:tool, :tool_code, :version, :last_seen_at, :status, :source_id) do
      def observed? = !last_seen_at.nil?
      def history? = !source_id.nil?
    end

    AGENT_CODE = "closeyourit-agent"
    # Problemi in cima (rosso → ambra → verde), poi per code: la card mostra subito cosa non riporta.
    STATUS_ORDER = { missing: 0, stale: 1, ok: 2 }.freeze

    def initialize(project)
      @project = project
    end

    def rows
      @rows ||= observed_sources.map do |observed|
        Row.new(
          tool: Monitoring::Tool.find(observed.tool_code) || Monitoring::Tool.new(observed.tool_code),
          tool_code: observed.tool_code,
          version: observed.version,
          last_seen_at: observed.last_seen_at,
          status: status_for(observed.last_seen_at),
          source_id: observed.source_id
        )
      end.sort_by { |row| [ STATUS_ORDER.fetch(row.status, 9), row.tool_code ] }
    end

    def any? = rows.any?
    def total = rows.size
    def ok_count = rows.count { |row| row.status == :ok }
    def missing_count = rows.count { |row| row.status == :missing }

    private

    # Stato temporale della fonte in base all'ultima attività vista.
    def status_for(last_seen_at)
      return :missing if last_seen_at.nil?

      age = Time.current - last_seen_at
      return :ok if age <= Projects::Constants::SOURCE_FRESH_WITHIN
      return :stale if age <= Projects::Constants::SOURCE_STALE_WITHIN

      :missing
    end

    # Fonti osservate per tool_code: l'agent derivato PRIMA, così una eventuale Projects::Source reale
    # con lo stesso code lo sovrascrive (una fonte reale batte il derivato).
    def observed_sources
      (agent_observed + source_observed).index_by(&:tool_code).values
    end

    # Scarta le fonti col nome redatto da uno scrubber SDK (es. "[FILTERED]"): non sono tool reali e
    # possono esistere in DB da prima del guard in Projects::Source.track! — mai in griglia.
    def source_observed
      @project.sources.reject { |source| Projects::Source.placeholder_code?(source.tool_code) }
              .map { |source| Observed.new(source.tool_code, source.version, source.last_seen_at, source.id) }
    end

    # Agent server: derivato a read-time dagli host linkati al progetto (l'agent è org-level, non ha una
    # riga projects_sources → nessuna cronologia, source_id nil). Prende l'host visto più di recente.
    def agent_observed
      hosts = @project.server_links.includes(:host).map(&:host).uniq
      return [] if hosts.empty?

      latest = hosts.max_by { |host| host.last_seen_at || Time.at(0) }
      [ Observed.new(AGENT_CODE, latest.agent_version, latest.last_seen_at, nil) ]
    end
  end
end
