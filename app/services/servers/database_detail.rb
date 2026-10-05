# frozen_string_literal: true

module Servers
  # Dettaglio di UN database per la sua pagina: quanto occupa sulla macchina aperta, su quali altre
  # macchine vive (copie comprese), quali sue tabelle pesano di più e a quale progetto sembra
  # appartenere. Legge solo lo snapshot già persistito — l'app non si connette mai ai database.
  class DatabaseDetail
    Presence = Data.define(:host_id, :host_name, :host_role, :host_status, :size_bytes, :last_seen_at)
    Table = Data.define(:name, :size_bytes)
    Result = Data.define(:name, :size_bytes, :share_pct, :host_total_bytes, :engine, :version, :host_role,
                         :db_reachable, :presences, :tables, :project)

    # Il database delle code di un progetto (`<key>_queue_<env>`) è dello stesso progetto.
    QUEUE_SUFFIX = "_queue"

    def self.call(host:, name:, hosts:, projects:) = new(host:, name:, hosts:, projects:).call

    def initialize(host:, name:, hosts:, projects:)
      @host = host
      @name = name.to_s
      @hosts = hosts
      @projects = projects
    end

    def call
      return nil if own_row.blank?

      Result.new(name: name, size_bytes: own_row.size_bytes, share_pct: own_row.share_pct,
                 host_total_bytes: own_row.host_total_bytes,
                 engine: snapshot(host)["engine"], version: snapshot(host)["version"],
                 host_role: own_row.host_role, db_reachable: own_row.db_reachable,
                 presences: presences, tables: tables, project: project)
    end

    private

    attr_reader :host, :name, :hosts, :projects

    def snapshot(record) = record.database_snapshot.is_a?(Hash) ? record.database_snapshot : {}

    # La riga di QUESTA macchina, senza accorpamenti: è la fonte di dimensione e quota mostrate.
    def own_row
      @own_row ||= DatabaseInventory.call(hosts: [ host ]).find { |row| row.name == name }
    end

    # Le macchine che ospitano il database. Il gruppo primary+copie NON viene ricalcolato qui: si
    # riusa quello che l'inventario ha già dedotto (regola unica, tre condizioni concordanti), sia
    # aprendo la pagina dal primary sia da una copia.
    def presences
      ids = group_host_ids
      by_id = hosts.index_by(&:id)
      ids.filter_map { |id| presence_for(by_id[id]) }
    end

    def group_host_ids
      row = grouped_rows.find { |candidate| candidate.host_id == host.id } ||
            grouped_rows.find { |candidate| candidate.replica_host_ids.include?(host.id) }
      return [ host.id ] if row.blank?

      [ row.host_id, *row.replica_host_ids ]
    end

    def grouped_rows
      @grouped_rows ||= DatabaseInventory.call(hosts: hosts).select { |row| row.name == name }
    end

    def presence_for(record)
      return nil if record.blank?

      entry = Array(snapshot(record)["databases"]).find { |item| item.is_a?(Hash) && item["name"] == name }
      Presence.new(host_id: record.id, host_name: record.name, host_role: snapshot(record)["role"],
                   host_status: record.status, size_bytes: entry&.dig("size_bytes")&.to_i,
                   last_seen_at: record.last_seen_at)
    end

    # `top_tables` è la classifica della MACCHINA: filtrata su questo database può benissimo essere
    # vuota (database piccolo), e la pagina lo dice invece di mostrare un riquadro muto.
    def tables
      Array(snapshot(host)["top_tables"])
        .select { |item| item.is_a?(Hash) && item["database"] == name && item["name"].present? }
        .sort_by { |item| -item["size_bytes"].to_i }
        .map { |item| Table.new(name: item["name"], size_bytes: item["size_bytes"].to_i) }
    end

    # Supposizione, non un collegamento: `koru_production` → progetto con key KORU. Si toglie il
    # suffisso dell'ambiente (e l'eventuale `_queue`) e si cerca UN solo progetto compatibile tra
    # quelli visibili — zero o più di uno → nessuna deduzione, meglio tacere che indicare il progetto
    # sbagliato. La view deve sempre etichettarlo come dedotto dal nome.
    def project
      return @project if defined?(@project)

      candidate = candidate_key
      @project = return_if_unique(candidate)
    end

    def candidate_key
      base = name.downcase
      suffix = environment_codes.select { |code| base.end_with?("_#{code}") }.max_by(&:length)
      base = base.delete_suffix("_#{suffix}") if suffix
      base.delete_suffix(QUEUE_SUFFIX)
    end

    def environment_codes
      @environment_codes ||= host.organization.environments.pluck(:code).map(&:to_s).reject(&:blank?)
    end

    def return_if_unique(candidate)
      return nil if candidate.blank?

      matches = projects.select do |record|
        record.key.to_s.downcase == candidate || record.name.to_s.parameterize(separator: "_") == candidate
      end
      matches.one? ? matches.first : nil
    end
  end
end
