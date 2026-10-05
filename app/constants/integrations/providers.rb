# frozen_string_literal: true

module Integrations
  # I servizi esterni che un'organizzazione può collegare con le proprie credenziali (CYRA-544).
  #
  # PORO costante come `Ai::Feature` e `Monitoring::Tool`, non tabella CRUD: il catalogo è
  # dev-defined — ogni voce ha un punto d'innesto scritto nel codice (il client che la usa e il
  # servizio che la verifica), quindi aggiungere un fornitore è lavoro di sviluppo, non un dato che
  # un utente possa creare.
  #
  # PERCHÉ ESISTE: fino a CYRA-543 ogni servizio esterno aveva UNA sola chiave, quella di chi gestisce
  # l'installazione. Costo e limite di consumo di tutte le organizzazioni erano a carico di una
  # persona, nessuno poteva usare il proprio account, e accendere un servizio a qualcuno richiedeva un
  # rilascio.
  #
  # NON è il freno d'emergenza del god (`Ai::Feature`): quello vale per tutte le organizzazioni
  # insieme e vive in Valhalla. I due si sommano — servizio spento dal god = spento per tutti; chiave
  # assente = spento per quella sola organizzazione.
  #
  # Etichette e spiegazioni via i18n (`integrations.providers.<key>.*`): qui vive solo la struttura.
  module Providers
    Provider = Data.define(:key, :icon, :color, :console_url, :features) do
      def label = I18n.t("integrations.providers.#{key}.label")
      def summary = I18n.t("integrations.providers.#{key}.summary")
      # Dove si va a prendere la chiave. È l'unica cosa che chi collega non può indovinare.
      def where = I18n.t("integrations.providers.#{key}.where")
    end

    # `features` sono le chiavi i18n delle funzioni che quel servizio accende: la pagina le elenca,
    # e sono anche quello che si spegne scollegando — dirlo prima è il minimo.
    # Dal CYRA-765 resta un solo fornitore collegabile. L'assistenza AI NON si collega più: gira sul
    # server generativo di casa con una chiave di sistema, quindi non c'è niente da incollare qui e
    # nessuna funzione che si spenga scollegando. Il registro non è vuoto e non lo diventerà: la
    # misura della velocità dei siti resta una chiave di chi la usa, sul suo account Google.
    REGISTRY = {
      "pagespeed" => Provider.new(
        key: "pagespeed", icon: "bolt", color: "amber",
        console_url: "https://console.cloud.google.com/apis/library/pagespeedonline.googleapis.com",
        features: %w[site_speed]
      )
    }.freeze

    # Il servizio non è collegato da questa organizzazione: la funzione non parte affatto (CYRA-548).
    # 503 e non 502: il fornitore sta benissimo, manca il collegamento da questa parte. Stessa forma
    # e stesso ragionamento di `Ai::Feature::ERROR_CODE`, che è il freno gemello del god.
    NOT_CONNECTED_CODE = "R503-INTEGRATION-006"

    module_function

    def keys = REGISTRY.keys
    def all = REGISTRY.values
    def known?(key) = REGISTRY.key?(key.to_s)

    # AppError pronto per il ramo `Result.err` dei service, con il nome leggibile del servizio.
    # Il fallback sulla chiave grezza serve al provider ritirato dal registro: una credenziale
    # rimasta di un servizio che non esiste più non deve far esplodere il messaggio d'errore.
    def not_connected_error(key)
      AppError.new(
        I18n.t("integrations.errors.not_connected", service: find(key)&.label || key.to_s),
        code: NOT_CONNECTED_CODE,
        status: :service_unavailable
      )
    end

    # Nil su chiave ignota invece di sollevare: il chiamante decide. Un provider sparito dal registro
    # (rinominato, ritirato) non deve far esplodere una pagina che elenca credenziali già salvate.
    def find(key) = REGISTRY[key.to_s]
  end
end
