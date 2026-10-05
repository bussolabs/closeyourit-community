# frozen_string_literal: true

module Integrations
  # Prova UNA credenziale collegata e scrive com'è andata.
  #
  # Nasce dallo stesso corpo che stava dentro `Integrations::VerifyJob` (CYRA-549): la prova e la
  # scrittura dell'esito stanno in un posto solo, così chi chiama non può scriverla in un modo suo.
  #
  # L'esito si SCRIVE SEMPRE, anche quando è «fornitore irraggiungibile»: la colonna dice cos'è
  # successo all'ULTIMA prova, e nasconderne una parte perché «forse era solo la rete» è il modo in
  # cui si costruisce una pagina che rassicura mentendo. Scriverlo non spegne niente:
  # `Integrations::Resolve` restituisce la chiave anche quando l'ultima prova è fallita, di proposito.
  #
  # NON avvisa più nessuno (CYRA-765). L'avviso che stava qui riguardava il solo servizio generativo,
  # che non è più una chiave di organizzazione: l'AI la offre il sistema, e a sorvegliarla è il
  # controllo della salute del server generativo. Quello che resta collegabile — la misura della
  # velocità dei siti — se la chiave muore lo dice da sé nella pagina che la mostra.
  class CheckCredential < ApplicationService
    def self.call(...) = new(...).call

    def initialize(credential:)
      @credential = credential
    end

    # → Result.ok(slug dell'esito negativo) oppure Result.ok(nil) se la chiave risponde.
    def call
      # Una riga rimasta di un servizio ritirato dal registro non si può provare: non esiste più una
      # sonda per quel fornitore. Marcarla «non funzionante» darebbe la colpa alla chiave di una
      # decisione che abbiamo preso noi.
      return Result.ok(nil) if @credential.provider_definition.nil?

      outcome = probe
      @credential.update!(verified_at: Time.current, verification_error: outcome)
      Result.ok(outcome)
    rescue StandardError => e
      # Un guasto su UNA credenziale non deve negare il controllo a tutte le altre — chi chiama
      # scorre un elenco, e lasciar propagare qui costerebbe il giro intero (col ritentativo di
      # ApplicationJob che ri-prova da capo anche le già fatte, sprecando chiamate al fornitore).
      #
      # Il messaggio dell'eccezione NON si scrive: un guasto dentro una chiamata autenticata può
      # portarsi dietro pezzi della richiesta, e la richiesta contiene la chiave. Restano la classe e
      # l'identificativo della riga, che bastano per andarci a guardare. Un `error` nei log è già un
      # evento per il monitoraggio di sé stesso, quindi questo rescue non nasconde niente a nessuno.
      Rails.logger.error("[integrations] verifica fallita per la credenziale #{@credential.id}: #{e.class}")
      Result.ok(nil)
    end

    private

    # → lo slug dell'esito negativo (invalid_key, unreachable, …), nil se la prova è passata. È lo
    # stesso vocabolario che finisce in colonna e che la pagina dei servizi sa già tradurre.
    def probe
      result = Integrations::Verify.call(provider: @credential.provider, api_key: @credential.api_key)
      result.ok? ? nil : result.error.details[:outcome]
    end
  end
end
