# frozen_string_literal: true

module Servers
  # Inventario piatto dei database dei server monitorati: espande lo snapshot jsonb dell'host
  # (`database_snapshot["databases"]`, già tradotto e cappato da Servers::Ingest::Normalize) in una
  # riga per database. Sorgente UNICA della pagina flotta e della tab del singolo server.
  # Filtro e ordinamento vivono in Ruby, non in SQL: le righe stanno dentro un jsonb, non in colonne.
  class DatabaseInventory
    # Chiavi ordinabili esposte alla tabella — stesso contratto di Sortable#current_sort
    # ("chiave" asc, "-chiave" desc), così Ui::TableComponent::HeaderComponent funziona invariato.
    SORT_KEYS = %w[database server size change].freeze
    # I database si guardano per peso: il più grande in cima.
    DEFAULT_SORT = "-size"
    # La variazione della lista è sempre a 7 giorni: la finestra breve che risponde a "cosa cresce".
    # Il dettaglio ha invece il selettore 24h/7d/30d. Uguale al DEFAULT_RANGE di ServerDatabasesController.
    CHANGE_RANGE = "7d"

    # `replica_host_names` e `replica_host_ids` sono la stessa lista in due letture: i nomi per la
    # tabella (che mostra macchine, non identificatori), gli id per chi deve poi ricaricare quegli
    # host (Servers::DatabaseDetail) — il nome dell'host non è unico, quindi non è una chiave.
    # Vengono riempiti insieme, in un unico punto.
    # `change_bytes` è la variazione di dimensione a 7g (dal primo all'ultimo campione della finestra),
    # nil quando non c'è storia sufficiente — popolato solo con `changes: true`, che la lista chiede e
    # il dettaglio no. Vive fuori dallo snapshot corrente perché nasce dai campioni storici.
    Row = Data.define(:host_id, :host_name, :host_status, :host_role, :db_reachable,
                      :name, :size_bytes, :share_pct, :host_total_bytes, :replica_host_names, :replica_host_ids,
                      :change_bytes)

    def self.call(hosts:, q: nil, sort: nil, changes: false) = new(hosts:, q:, sort:, changes:).call

    def initialize(hosts:, q: nil, sort: nil, changes: false)
      @hosts = hosts
      @query = q.to_s.strip.downcase
      @sort = SORT_KEYS.include?(sort.to_s.delete_prefix("-")) ? sort.to_s : DEFAULT_SORT
      @changes = changes
    end

    # L'accorpamento viene PRIMA del filtro: deve vedere tutte le righe, anche quelle che una ricerca
    # testuale escluderebbe, altrimenti una replica filtrata via lascerebbe la sua gemella orfana.
    # La variazione si aggancia DOPO l'accorpamento (una query sui campioni per le sole righe rimaste)
    # e PRIMA dell'ordinamento, che su di essa può ordinare.
    def call = sorted(with_changes(filtered(merged(rows))))

    private

    attr_reader :hosts, :query, :sort, :changes

    # Ordinati per nome, non come li restituisce il database (CYRA-772). Senza un ordine esplicito
    # PostgreSQL è libero di consegnare le righe come gli conviene, e `merged` assorbe le repliche
    # nell'ordine in cui le incontra: con due standby gemelli e UNA sola replica dichiarata dal
    # primario, quale finisce accorpato e quale resta riga a sé diventa arbitrario — cambia fra una
    # macchina e l'altra, e in pagina l'utente vede due risultati diversi per gli stessi dati.
    def rows = hosts.sort_by { |host| host.name.to_s }.flat_map { |host| rows_for(host) }

    # La quota è sul totale dei database dello STESSO host: confrontare un database di staging col
    # totale della flotta lo farebbe sparire nell'arrotondamento. Il totale (`host_total_bytes`) è il
    # denominatore, esposto per riga così la tabella può renderlo consultabile nel tooltip (CYRA-466).
    def rows_for(host)
      entries = entries_for(host)
      return [] if entries.empty?

      declared_replicas[host.id] = Array(snapshot(host).dig("replication", "replicas")).size
      cluster_ids[host.id] = snapshot(host)["system_identifier"]
      total = entries.sum { |entry| entry[:size_bytes] }
      entries.map do |entry|
        Row.new(host_id: host.id, host_name: host.name, host_status: host.status,
                host_role: snapshot(host)["role"], db_reachable: snapshot(host)["reachable"],
                name: entry[:name], size_bytes: entry[:size_bytes],
                share_pct: total.positive? ? (entry[:size_bytes] * 100.0 / total).round(1) : nil,
                host_total_bytes: total,
                replica_host_names: [], replica_host_ids: [], change_bytes: nil)
      end
    end

    # Un database su una replica in streaming È lo stesso dato del primary, con lo stesso peso: due
    # righe gemelle raddoppiano l'elenco e il totale dello spazio. Le righe della replica vengono
    # quindi assorbite da quelle del primary, che ne elenca il nome.
    #
    # Chi assorbe chi si stabilisce in due passaggi, nell'ordine — chi non dichiara un ruolo non
    # assorbe né viene assorbito, e in mancanza di una risposta certa si lasciano righe separate, che
    # sono ridondanti ma vere:
    #
    #   1. CERTIFICATO (agent >= 0.6.0). Gli host dichiarano il `system_identifier` del cluster, che
    #      Postgres tiene identico sul primary e su tutte le sue repliche fisiche: stesso valore =
    #      stesso cluster, punto. Nessun'altra condizione serve — né che il primary veda la replica
    #      connessa (una copia appena riavviata non è ancora in pg_stat_replication), né che gli
    #      elenchi dei database coincidano (un database appena creato non è ancora sulla copia).
    #
    #   2. DEDOTTO (fallback per gli agent più vecchi, che il campo non lo mandano). Senza legame
    #      certificato la relazione si indovina a livello di HOST, e solo quando TRE condizioni
    #      concordano: (a) il primary dichiara repliche connesse (`replication.replicas`) e ne
    #      assorbe al più quante ne dichiara; (b) l'elenco dei database COINCIDE esattamente — una
    #      replica copia il cluster intero, un solo nome in comune non basta; (c) il primary
    #      compatibile è uno solo. Il tetto di (a) conta anche le copie già assorbite al passo 1.
    def merged(rows)
      names_by_id = rows.to_h { |row| [ row.host_id, row.host_name ] }
      primary_ids = rows.select { |row| row.host_role == "primary" }.map(&:host_id).uniq
      standby_ids = rows.select { |row| row.host_role == "standby" }.map(&:host_id).uniq
      replicas_of = Hash.new { |hash, key| hash[key] = [] }

      undecided = standby_ids.reject do |standby_id|
        primary_id = certified_primary_for(standby_id, primary_ids)
        next false unless primary_id

        replicas_of[primary_id] << standby_id
        true
      end

      names_by_host = rows.group_by(&:host_id).transform_values { |host_rows| host_rows.map(&:name).to_set }
      deducible_ids = primary_ids.select { |id| declared_replicas[id].to_i.positive? }
      undecided.each do |standby_id|
        targets = deducible_ids.select do |primary_id|
          !conflicting_clusters?(primary_id, standby_id) &&
            names_by_host[primary_id] == names_by_host[standby_id]
        end
        next unless targets.one? && replicas_of[targets.first].size < declared_replicas[targets.first].to_i

        replicas_of[targets.first] << standby_id
      end

      # Per ID, mai per nome: due macchine possono chiamarsi uguale (il nome non è unico) e solo
      # quella assorbita deve sparire dall'elenco.
      absorbed_ids = replicas_of.values.flatten.to_set
      rows.filter_map do |row|
        next nil if absorbed_ids.include?(row.host_id)

        ids = replicas_of[row.host_id].uniq.sort_by { |id| names_by_id[id].to_s }
        next row if ids.empty?

        row.with(replica_host_ids: ids, replica_host_names: ids.map { |id| names_by_id[id] })
      end
    end

    # Il primary dello stesso cluster della copia, quando ce n'è esattamente uno. Due primary che
    # dichiarano lo stesso cluster sono uno stato anomalo — due macchine che si credono entrambe
    # l'originale — e sceglierne una a caso sarebbe peggio che lasciare le righe separate.
    def certified_primary_for(standby_id, primary_ids)
      identifier = cluster_ids[standby_id]
      return nil if identifier.blank?

      targets = primary_ids.select { |primary_id| cluster_ids[primary_id] == identifier }
      targets.first if targets.one?
    end

    # Due host che dichiarano cluster DIVERSI non sono copie l'uno dell'altro, e questa è una
    # risposta certa: la deduzione sui nomi non deve poterla ribaltare (è proprio il falso positivo
    # che il campo elimina). Se uno dei due tace non c'è conflitto e si deduce come prima.
    def conflicting_clusters?(one_id, other_id)
      one = cluster_ids[one_id]
      other = cluster_ids[other_id]

      one.present? && other.present? && one != other
    end

    # Quante repliche il primary dichiara di avere connesse, per host: il tetto di ciò che può
    # assorbire. Popolata mentre si espandono le righe (unico giro sugli host).
    def declared_replicas = @declared_replicas ||= {}

    # L'identificativo del cluster dichiarato da ogni host, per id — nil se l'agent non è ancora
    # aggiornato. Popolata nello stesso giro di declared_replicas.
    def cluster_ids = @cluster_ids ||= {}

    # Difensivo come il pannello della show: uno snapshot monco (push a metà, campo assente, voce
    # senza nome) non deve far esplodere la pagina — la riga sporca sparisce, il resto si vede.
    def snapshot(host) = host.database_snapshot.is_a?(Hash) ? host.database_snapshot : {}

    def entries_for(host)
      list = snapshot(host)["databases"]
      return [] unless list.is_a?(Array)

      list.filter_map do |item|
        next unless item.is_a?(Hash) && item["name"].to_s.present?

        { name: item["name"].to_s, size_bytes: item["size_bytes"].to_i }
      end
    end

    # Una sola casella di ricerca per due colonne: "staging" trova sia il database sia la macchina.
    # Anche i nomi delle repliche contano: dopo l'accorpamento sono l'unico posto in cui quella
    # macchina compare, e cercarla deve restituire la riga che la nomina.
    def filtered(rows)
      return rows if query.blank?

      rows.select do |row|
        row.name.downcase.include?(query) || row.host_name.downcase.include?(query) ||
          row.replica_host_names.any? { |replica| replica.downcase.include?(query) }
      end
    end

    # Le righe senza valore ordinabile (solo la variazione può mancare: "—") restano SEMPRE in fondo,
    # in entrambe le direzioni — un database di cui non sappiamo la crescita non deve galleggiare in
    # cima all'ordinamento decrescente. Per gli altri criteri non c'è mai un buco, quindi il partition
    # lascia tutto com'era.
    def sorted(rows)
      key = sort.delete_prefix("-")
      present, missing = rows.partition { |row| sort_present?(row, key) }
      ordered = present.sort_by { |row| sort_value(row, key) }
      ordered.reverse! if sort.start_with?("-")
      ordered + missing
    end

    def sort_present?(row, key) = key != "change" || !row.change_bytes.nil?

    # Tie-break espliciti: sort_by non è stabile, senza secondo criterio l'ordine di due righe
    # equivalenti cambierebbe da una richiesta all'altra.
    def sort_value(row, key)
      case key
      when "database" then [ row.name.downcase, row.host_name.downcase ]
      when "server" then [ row.host_name.downcase, row.name.downcase ]
      when "change" then [ row.change_bytes, row.name.downcase ]
      else [ row.size_bytes, row.name.downcase ]
      end
    end

    # La variazione a 7g per le righe rimaste, per (host, nome): una sola query batch sui campioni,
    # solo quando la lista la chiede. Le righe accorpate portano l'host_id del primary, che è la fonte
    # dello storico — la variazione è quindi già quella giusta.
    def with_changes(rows)
      return rows unless changes

      deltas = Servers::Sample.database_size_changes(host_ids: rows.map(&:host_id).uniq, range: CHANGE_RANGE)
      rows.map { |row| row.with(change_bytes: deltas[[ row.host_id, row.name ]]) }
    end
  end
end
