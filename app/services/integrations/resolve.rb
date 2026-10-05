# frozen_string_literal: true

module Integrations
  # L'UNICA porta da cui il codice applicativo chiede la credenziale di un'organizzazione (CYRA-544).
  #
  # L'ORGANIZZAZIONE È UN ARGOMENTO OBBLIGATORIO, mai `Current.organization` implicito. È la
  # decisione che tiene in piedi tutta la lavorazione, e vale la pena spiegarla per esteso.
  #
  # Un job che dimentica di impostare il contesto, con la lettura implicita, vedrebbe «nessuna
  # organizzazione» e quindi «nessuna chiave» — e la funzione si spegnerebbe in silenzio, senza un
  # errore, senza una riga di log, senza niente da guardare. In questo prodotto è già successo: il
  # servizio degli embedding è rimasto irraggiungibile per un giorno e mezzo e non se n'è accorto
  # nessuno, perché il degrado era silenzioso per costruzione.
  #
  # Con l'argomento obbligatorio, la stessa dimenticanza diventa un `ArgumentError` al primo giro di
  # test. Un guasto rumoroso in sviluppo vale mille degradi eleganti in produzione.
  #
  # Nessuna cache in v1: una lettura su indice unico più una decifratura, su chiamate che durano
  # secondi. Si aggiungerà quando servirà, non prima.
  module Resolve
    module_function

    # → la chiave, oppure nil se l'organizzazione non ha collegato quel servizio.
    #
    # Restituisce la chiave anche quando l'ultima verifica è fallita: una chiave che ieri non
    # rispondeva potrebbe rispondere oggi (un limite temporaneo, una rete storta), e rifiutarsi di
    # provarla sarebbe decidere al posto del fornitore. La verifica serve a DIRLO in pagina, non a
    # bloccare.
    def api_key(organization:, provider:)
      credential_for(organization:, provider:)&.api_key.presence
    end

    # Il predicato che decide se accodare lavoro. Legge la sola presenza: non decifra niente.
    def connected?(organization:, provider:)
      credential_for(organization:, provider:).present?
    end

    # Quali servizi ha collegato: per la pagina e per i controlli in blocco, senza N+1 e senza
    # decifrare un solo valore.
    def connected_providers(organization:)
      raise ArgumentError, "organization mancante" if organization.nil?

      Integrations::Credential.where(organization_id: id_of(organization)).pluck(:provider).to_set
    end

    def credential_for(organization:, provider:)
      raise ArgumentError, "organization mancante" if organization.nil?
      raise ArgumentError, "servizio sconosciuto: #{provider}" unless Integrations::Providers.known?(provider)

      Integrations::Credential.find_by(organization_id: id_of(organization), provider: provider.to_s)
    end

    # Accetta l'organizzazione o il suo id: i job hanno spesso solo l'id, e obbligarli a ricaricare
    # il record per leggere una chiave sarebbe una query in più per niente.
    def id_of(organization) = organization.respond_to?(:id) ? organization.id : organization
  end
end
