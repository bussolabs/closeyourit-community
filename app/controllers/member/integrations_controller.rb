# frozen_string_literal: true

module Member
  # I servizi esterni che questa organizzazione collega con le proprie chiavi (CYRA-545).
  #
  # Le credenziali per-organizzazione esistevano già (CYRA-544) ma non c'era una schermata da cui
  # incollarle: si scrivevano da console, oppure restavano quelle dell'operatore. Chi amministra
  # vedeva funzioni spente e nessun posto dove accenderle.
  #
  # Tre regole, e sono tutte qui dentro:
  #
  # 1. LA CHIAVE SI PROVA SUL MOMENTO. `Integrations::Verify` fa una chiamata vera prima di salvare:
  #    una chiave storta si manifesta adesso, come messaggio rosso, invece che fra tre settimane come
  #    una funzione che tace. Costa qualche secondo di attesa al salvataggio ed è il prezzo giusto.
  # 2. UNA CHIAVE RIFIUTATA NON SI SCRIVE. Nemmeno sopra una che funzionava: chi sbaglia a incollare
  #    non deve restare senza il collegamento che aveva prima.
  # 3. CAMPO VUOTO = INVARIATO (come `Member::AlertingChannelsController#channel_attributes`). Il
  #    form non ripopola mai la chiave — non si rilegge, si sostituisce — quindi «vuoto» vuol dire
  #    «non l'ho toccata», mai «cancellala».
  #
  # Gate `organization.manage`: la stessa chiave che apre la pagina della GitHub App. La credenziale
  # è dell'organizzazione, si paga con l'account di chi la collega e vale per tutti i progetti.
  class IntegrationsController < Member::BaseController
    before_action :require_org_manage
    before_action :set_provider, only: %i[update destroy]

    def index
      @providers = ::Integrations::Providers.all
      # Le credenziali in un colpo solo: la pagina interroga lo stato di ogni servizio e senza questo
      # sarebbe una query per scheda. Il valore cifrato non viene decifrato da nessuna di queste letture.
      @credentials = Current.organization.integration_credentials.index_by(&:provider)
      @github_installation = Current.organization.github_installation
      counts
    end

    def update
      api_key = submitted_api_key
      return blank_key_outcome if api_key.blank?

      result = ::Integrations::Verify.call(provider: @provider.key, api_key: api_key)
      return redirect_to(member_integrations_path, alert: result.error.message) if result.err?

      connect(api_key)
      redirect_to member_integrations_path,
                  notice: t("member.integrations.connected_notice", service: @provider.label)
    end

    def destroy
      credential&.destroy
      redirect_to member_integrations_path,
                  notice: t("member.integrations.disconnected_notice", service: @provider.label)
    end

    private

    def require_org_manage
      require_permission!("organization.manage")
    end

    # I numeri in cima. GitHub è contato fra i servizi perché in questa pagina è un servizio come gli
    # altri, solo senza una chiave da incollare: escluderlo direbbe «tre collegati su tre» a chi ne
    # vede quattro in elenco. I collegati si contano sui servizi del registro, non sulle righe: una
    # credenziale rimasta di un fornitore ritirato non compare in pagina e non deve entrare nel conto.
    def counts
      @services_count = @providers.size + 1
      @broken_count = @providers.count { |provider| @credentials[provider.key]&.broken? }
      @connected_count = @providers.count { |provider| @credentials[provider.key] } +
                         (@github_installation ? 1 : 0)
    end

    # Un servizio che non esiste torna all'elenco: l'indirizzo è scritto a mano o manomesso, e una
    # pagina d'errore non aggiungerebbe niente a chi ci arriva. Stessa scelta anti-tamper di
    # `Navigation::Group.find`.
    def set_provider
      @provider = ::Integrations::Providers.find(params[:provider])
      redirect_to member_integrations_path, alert: t("member.integrations.unknown_service") if @provider.nil?
    end

    def credential
      return @credential if defined?(@credential)

      @credential = Current.organization.integration_credentials.find_by(provider: @provider.key)
    end

    # Il campo porta il nome del servizio (`api_key_pagespeed`) perché nella pagina i moduli sono uno
    # per scheda: con un nome solo, i campi di due schede condividerebbero lo stesso identificativo
    # HTML e l'etichetta di ciascuna punterebbe al campo della prima.
    def submitted_api_key
      params[:"api_key_#{@provider.key}"].to_s.strip
    end

    # `find_or_initialize_by`: la credenziale è una per organizzazione e per servizio (indice unico),
    # quindi collegare e sostituire sono lo stesso gesto. `verified_at` si scrive QUI, nello stesso
    # passaggio della chiave, perché la prova appena fatta parla di questa chiave: il modello azzera
    # l'esito quando la chiave cambia e senza questo la pagina direbbe «mai provata» un istante dopo
    # averla provata.
    def connect(api_key)
      record = Current.organization.integration_credentials.find_or_initialize_by(provider: @provider.key)
      record.assign_attributes(api_key: api_key, verified_at: Time.current, verification_error: nil,
                               connected_by: Current.account)
      record.save!
    end

    # Salvare senza toccare il campo non è un errore quando la chiave c'è già: è il caso normale di chi
    # riapre la pagina, e la chiave resta dov'è. Lo è invece su un servizio mai collegato, dove non
    # c'è niente da provare e niente da salvare.
    def blank_key_outcome
      if credential
        redirect_to member_integrations_path,
                    notice: t("member.integrations.unchanged_notice", service: @provider.label)
      else
        redirect_to member_integrations_path,
                    alert: t("member.integrations.missing_key", service: @provider.label)
      end
    end
  end
end
