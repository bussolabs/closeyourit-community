# frozen_string_literal: true

module Integrations
  # Il passaggio dalla chiave unica alle chiavi di ciascuno, fatto una volta sola (CYRA-549).
  #
  # Prende le chiavi che oggi stanno nell'ambiente — quelle di chi gestisce l'installazione — e le
  # scrive come credenziali di UNA organizzazione: la sua.
  #
  # PERCHÉ SOLO UNA. Copiarle in tutte le organizzazioni sarebbe la migrazione più comoda e sarebbe
  # anche l'esatto contrario di ciò che questa lavorazione esiste per ottenere: costo e limite di
  # consumo resterebbero a carico di una persona sola, con in più l'inganno di una pagina che dice a
  # ciascuno «hai collegato il tuo servizio» mentre sta consumando la quota di qualcun altro. Le
  # altre organizzazioni partono NON collegate, ed è il dato onesto: nessuno ha ancora portato le
  # proprie credenziali.
  #
  # Non fa nessuna chiamata di rete. La prova costa un giro dal fornitore per servizio, e farla qui
  # significherebbe un rilascio che si blocca perché Google è lento: la credenziale nasce «mai
  # provata» e il giro giornaliero (`Integrations::VerifyJob`) la prova entro il giorno dopo.
  #
  # È idempotente per costruzione: una credenziale già presente non si tocca mai. Un secondo giro
  # rimetterebbe la chiave dell'operatore al posto di una chiave che qualcuno ha scelto apposta.
  class AdoptSystemKeys < ApplicationService
    # Da quale variabile d'ambiente arriva la chiave di ciascun servizio. Vive QUI e non nel registro
    # `Integrations::Providers` perché è un legame a termine: descrive com'erano le cose prima del
    # passaggio, non come sono. Un servizio aggiunto al registro domani non ha nessuna chiave di
    # sistema da adottare, e una mappa nel registro suggerirebbe il contrario per sempre.
    # Dal CYRA-765 è rimasta una sola voce: la chiave del servizio generativo non si adotta più,
    # perché l'AI non è più una chiave di organizzazione (la mette il sistema). La mappa resta una
    # mappa, e non una costante sola, perché è la forma del legame a termine che descrive.
    ENV_KEYS = {
      "pagespeed" => "GOOGLE_PAGESPEED_API_KEY"
    }.freeze

    # `organization` obbligatoria e senza default, come in `Integrations::Resolve`: una chiave senza
    # un padrone esplicito non si scrive da nessuna parte. Qui il default implicito non sarebbe un
    # degrado silenzioso, sarebbe una credenziale finita nell'organizzazione sbagliata.
    def initialize(organization:, env: ENV)
      raise ArgumentError, "organization mancante" if organization.nil?

      @organization_id = Integrations::Resolve.id_of(organization)
      @env = env
    end

    # → Result.ok con l'elenco dei servizi adottati (vuoto se non c'era niente da adottare).
    def call
      Result.ok(ENV_KEYS.filter_map { |provider, variable| adopt(provider, @env[variable]) })
    end

    private

    def adopt(provider, api_key)
      return if api_key.to_s.strip.blank?
      return if Integrations::Credential.exists?(organization_id: @organization_id, provider: provider)

      Integrations::Credential.create!(organization_id: @organization_id, provider: provider, api_key: api_key)
      provider
    end
  end
end
