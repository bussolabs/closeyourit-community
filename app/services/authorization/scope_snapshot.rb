# frozen_string_literal: true

module Authorization
  # CYRA-812 — il perimetro con cui parte una domanda all'AI, e cosa ne resta quando il lavoro gira.
  #
  # Le domande all'assistente e i RAG non rispondono nel giro della richiesta: il perimetro visibile
  # si fotografa quando la domanda parte e viaggia con il lavoro. Ricalcolarlo da capo a valle
  # darebbe il perimetro di un altro momento, e con un god che impersona darebbe quello sbagliato —
  # per questo la fotografia resta. Ma la fotografia è un TETTO, non un lasciapassare: fra l'invio e
  # l'esecuzione possono passare minuti, e in quei minuti l'accesso a un progetto può essere tolto.
  # Chi legge i dati deve quindi partire dal tetto e ripassarlo dal perimetro di ADESSO:
  #
  #   tetto ∩ perimetro attuale
  #
  # L'intersezione fa due cose in una: rispetta le revoche (chi non vede più il progetto non lo
  # legge) e non lascia entrare i permessi arrivati DOPO la domanda (il tetto non si alza mai).
  # #reduced dice se qualcosa è caduto, così chi risponde può dirlo invece di consegnare in silenzio
  # una risposta più povera di quella che ci si aspettava.
  #
  # L'attore va passato esplicitamente: nel giro asincrono non c'è Current, e usare l'account
  # "visto" al posto di quello effettivo ridurrebbe un god che impersona al perimetro dell'impersonato.
  ScopeSnapshot = Data.define(:project_ids, :group_ids, :full_access, :listed, :reduced) do
    # `listed` = l'elenco descrive il perimetro PER INTERO. Va detto e non dedotto: un owner di
    # un'organizzazione ancora vuota produce un elenco vuoto identico a quello con cui i lavori
    # accodati prima di CYRA-812 dicevano «tutta l'organizzazione», e senza questo flag i progetti
    # nati fra la domanda e la risposta entrerebbero nel perimetro di una domanda che non li
    # comprendeva. Nasce vero: solo chi ricostruisce un tetto vecchio dichiara il contrario.
    #
    # Quello che l'elenco protegge è la lettura per ID — ticket e progetti. Sulla knowledge base
    # `full_access` continua a voler dire ORGANIZZAZIONE e non un elenco, perché le pagine non
    # appartengono a un progetto e quelle valide per tutti non ne hanno nessuno: restringerle
    # all'elenco toglierebbe all'owner proprio quelle. Quel perimetro è stabile lo stesso — cambia
    # solo se il permesso cambia, e allora `full_access` cade.
    def initialize(listed: true, reduced: false, **) = super

    # Fotografia del perimetro di chi sta chiedendo, ADESSO. L'elenco esplicito si tiene ANCHE per
    # chi ha accesso pieno, per lo stesso motivo di sopra.
    def self.capture(account:, organization:)
      scope = VisibleScope.new(account: account, organization: organization)
      new(project_ids: scope.projects.pluck(:id), group_ids: scope.groups.pluck(:id),
          full_access: VisibleScope.unscoped?(account: account, organization: organization))
    end

    # Ricostruzione del tetto dagli argomenti di un lavoro accodato (Hash con chiavi stringa o nil).
    # `listed` arriva dal lavoro stesso e nasce FALSO: un lavoro rimasto in coda dal rilascio
    # precedente non lo porta, ed è esattamente quello per cui il ramo senza elenco esiste.
    def self.frozen(project_ids:, group_ids:, full_access:, listed: false)
      new(project_ids: Array(project_ids), group_ids: Array(group_ids),
          full_access: full_access.present?, listed: listed.present?)
    end

    # Tetto senza elenco: la forma dei lavori accodati PRIMA di CYRA-812, dove l'elenco vuoto con
    # accesso pieno significava «tutta l'organizzazione». Vale solo per quelli rimasti in coda al
    # rilascio: le fotografie nuove dichiarano il proprio elenco e non passano mai di qui.
    def unbounded? = full_access && !listed && project_ids.empty? && group_ids.empty?

    # The same snapshot cut down to one project: no groups and no full access, so the knowledge
    # base too is read through that project alone. A project outside the snapshot leaves nothing.
    def only_project(project_id)
      self.class.new(project_ids: project_ids & [ project_id ], group_ids: [], full_access: false)
    end

    # Data non genera i predicati: questo si legge in mezzo a una frase e vale la riga.
    def reduced? = reduced

    def narrow(account:, organization:)
      now = self.class.capture(account: account, organization: organization)
      access = full_access && now.full_access
      projects = unbounded? ? now.project_ids : project_ids & now.project_ids
      groups = unbounded? ? now.group_ids : group_ids & now.group_ids

      # L'esito è sempre `listed`: l'elenco appena calcolato È il perimetro, non un suo riassunto.
      self.class.new(project_ids: projects, group_ids: groups, full_access: access,
                     reduced: shrunk?(access, projects, groups))
    end

    private

    # Ristretto = qualcosa che il tetto comprendeva non c'è più. Sul tetto illimitato l'elenco non
    # esiste, quindi l'unico segnale è l'accesso pieno che cade: senza di quello non si può dire che
    # sia stato tolto niente, e gridare al lupo su ogni domanda sarebbe peggio che tacere.
    def shrunk?(access, projects, groups)
      return true if full_access && !access
      return false if unbounded?

      projects.size < project_ids.size || groups.size < group_ids.size
    end
  end
end
