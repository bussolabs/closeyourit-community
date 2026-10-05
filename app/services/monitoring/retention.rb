# frozen_string_literal: true

module Monitoring
  # La regola di conservazione dei dati, in un punto solo (CYRA-734).
  #
  # Sei domini — log, analytics, errori, performance, uptime, campioni dei server — decidono per
  # quanti giorni tenere i propri dati con la STESSA regola nearest-wins: vince il livello più
  # vicino al dato che dichiara un valore positivo (progetto → organizzazione → globale god →
  # default di sistema). NON è un cap: un progetto può tenere PIÙ a lungo della sua organizzazione.
  # Un valore assente, blank, zero o negativo non è una scelta di conservare meno, è un valore che
  # manca: eredita dal livello superiore.
  #
  # Prima ogni dominio ricopiava la catena nel proprio modulo (stessa logica; cambiavano solo il
  # nome dell'attributo e il default), e cambiare la regola voleva dire cambiarla sei volte. Erano
  # già divergenti: dove logs e analytics passavano di qui, gli altri quattro prendevano alla
  # lettera un globale pre-risolto a zero — cioè avrebbero potato tutto. Qui la catena è una sola;
  # ogni dominio dichiara la propria riga in DOMAINS, e i moduli per-dominio (Logs::Retention,
  # Errors::Retention, ...) restano come nome del dominio per chiamanti e viste, delegando qui.
  module Retention
    # Una riga del catalogo. `attribute` è omonimo sui tre livelli (progetto, organizzazione,
    # Settings::Global): è la convenzione che permette una catena sola. `scope` dice a chi
    # appartiene il dato — i campioni dei server sono org-scoped nel data model (Servers::Sample e
    # Host belongs_to :organization, niente project_id — CYRA-159), quindi per loro il livello
    # progetto non esiste e lo scope ricevuto è già l'organizzazione.
    Domain = Data.define(:attribute, :default, :scope)

    DOMAINS = {
      artifacts: Domain.new(attribute: :artifacts_retention_days, default: 30, scope: :project),
      crashes: Domain.new(attribute: :crashes_retention_days, default: 30, scope: :project),
      session_health: Domain.new(attribute: :session_health_retention_days, default: 30, scope: :project),
      measurements: Domain.new(attribute: :measurements_retention_days, default: 14, scope: :project),
      traces: Domain.new(attribute: :traces_retention_days, default: 14, scope: :project),
      logs: Domain.new(attribute: :logs_retention_days,
                       default: Logs::Constants::RETENTION_DEFAULT_DAYS, scope: :project),
      analytics: Domain.new(attribute: :analytics_retention_days,
                            default: Analytics::Constants::RETENTION_DEFAULT_DAYS, scope: :project),
      errors: Domain.new(attribute: :errors_retention_days,
                         default: Errors::Constants::RETENTION_DEFAULT_DAYS, scope: :project),
      metrics: Domain.new(attribute: :performance_retention_days,
                          default: Metrics::Constants::RETENTION_DEFAULT_DAYS, scope: :project),
      uptime: Domain.new(attribute: :uptime_retention_days,
                         default: Uptime::Constants::RETENTION_DEFAULT_DAYS, scope: :project),
      servers: Domain.new(attribute: :servers_retention_days,
                          default: Servers::Constants::RETENTION_DEFAULT_DAYS, scope: :organization)
    }.freeze

    module_function

    # Giorni di conservazione per `scope` (un progetto, o l'organizzazione per i domini org-scoped).
    #
    # `global_days` può arrivare già risolto dal chiamante: i job di potatura leggono il singleton
    # god UNA volta per tutti i progetti invece di una per progetto. `:unset` significa «leggilo
    # tu», e la lettura resta pigra — un progetto che ha già un valore proprio non tocca mai il
    # singleton. Una chiave fuori catalogo solleva KeyError: un dominio nuovo che si dimentica la
    # propria riga deve accorgersene subito, non ereditare in silenzio una finestra arbitraria.
    def for(scope, key:, global_days: :unset)
      domain = DOMAINS.fetch(key)

      resolve(scope.public_send(domain.attribute)) ||
        resolve(organization_days(scope, domain)) ||
        resolve(global_days == :unset ? Settings::Global.instance.public_send(domain.attribute) : global_days) ||
        domain.default
    end

    # Intero positivo o nil (un valore assente/zero/negativo/blank → eredita).
    def resolve(value)
      days = value.to_i
      days if days.positive?
    end

    # La finestra PIÙ LUNGA in vigore per un dominio, su tutti i clienti (CYRA-750).
    #
    # Serve a decidere quando una FETTA intera di una tabella di telemetria è staccabile: la fetta
    # contiene le righe di tutti i progetti, quindi si butta solo quando nessuno ha più diritto a
    # niente di ciò che c'è dentro. Non è la stessa cosa della finestra di un singolo cliente ed è
    # volutamente prudente: si prende il massimo fra tutti i valori dichiarati a ogni livello e il
    # default, senza risolvere la catena per ognuno. Il risultato è un limite SUPERIORE a ogni
    # finestra effettiva — può tenere una fetta qualche giorno più del necessario, non può mai
    # buttarne una che qualcuno doveva ancora avere. Il residuo lo potano i giri di sempre, riga per
    # riga, ciascuno con la finestra vera del proprio cliente.
    #
    # `global_days` arriva già risolto dai giri di potatura, come in `.for`: il singleton god si legge
    # una volta sola per giro, non una per domanda.
    def longest(key:, global_days: :unset)
      domain = DOMAINS.fetch(key)
      global = global_days == :unset ? Settings::Global.instance.public_send(domain.attribute) : global_days
      candidates = [ domain.default,
                     resolve(global).to_i,
                     stored_maximum(Organizations::Organization, domain.attribute) ]
      candidates << stored_maximum(Projects::Project, domain.attribute) if domain.scope == :project
      candidates.max
    end

    # Le finestre per-cliente vivono nelle preferenze (jsonb), non in una colonna: il massimo si
    # chiede al database con un'unica lettura invece di caricare progetti e organizzazioni. Il
    # confronto con la forma numerica non è ornamentale — una preferenza scritta a mano con un
    # valore non numerico farebbe fallire la conversione e con essa l'intera potatura notturna.
    def stored_maximum(model, attribute)
      column = model.connection.quote(attribute.to_s)
      model.connection.select_value(<<~SQL.squish).to_i
        SELECT MAX(CASE WHEN preferences->>#{column} ~ '^[0-9]+$'
                        THEN (preferences->>#{column})::int END)
        FROM #{model.quoted_table_name}
      SQL
    end
    private_class_method :stored_maximum

    # Il livello intermedio esiste solo per i domini con livello progetto: per un dominio org-scoped
    # lo `scope` ricevuto È già l'organizzazione, quindi il livello è stato letto al giro prima.
    def organization_days(scope, domain)
      return nil unless domain.scope == :project

      scope.organization.public_send(domain.attribute)
    end
    private_class_method :organization_days
  end
end
