# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Integrations
  # Prova una credenziale contro il fornitore, con una chiamata vera e la più piccola possibile
  # (CYRA-544).
  #
  # PERCHÉ ESISTE: una chiave incollata storta, senza questa prova, non si manifesta al salvataggio.
  # Si manifesta più tardi, come una funzione che tace — ed è il modo in cui le cose si rompono in
  # questo prodotto senza che nessuno se ne accorga. La prova trasforma un mistero futuro in un
  # messaggio rosso adesso.
  #
  # L'esito salvato è SEMPRE un codice nostro, mai il messaggio libero del fornitore: quel messaggio
  # può contenere pezzi della richiesta, e una chiave finita in una colonna di testo è una chiave in
  # chiaro.
  class Verify < ApplicationService
    # I quattro esiti che chi legge la pagina deve poter distinguere. «Non valida» e «servizio non
    # abilitato» sembrano la stessa cosa e si risolvono in due posti diversi: la prima si ri-copia,
    # la seconda si accende nella console del fornitore.
    #
    # Questi slug sono anche il valore persistito in `verification_error` e la chiave i18n del
    # messaggio: un posto solo, così non possono divergere.
    INVALID_KEY = "invalid_key"
    SERVICE_DISABLED = "service_disabled"
    KEY_RESTRICTED = "key_restricted"
    UNREACHABLE = "unreachable"
    UPSTREAM_ERROR = "upstream_error"

    # `Result.err` porta un AppError, non una stringa (vedi `app/services/result.rb`): è il contratto
    # del progetto, ed è quello che i controller si aspettano di poter interrogare con
    # `code`/`status`/`message`. Lo slug dell'esito viaggia in `details`, perché è quello che va
    # scritto in colonna.
    OUTCOMES = {
      INVALID_KEY => { code: "R422-INTEGRATION-001", status: :unprocessable_content },
      SERVICE_DISABLED => { code: "R422-INTEGRATION-002", status: :unprocessable_content },
      UNREACHABLE => { code: "R504-INTEGRATION-003", status: :gateway_timeout },
      UPSTREAM_ERROR => { code: "R502-INTEGRATION-004", status: :bad_gateway },
      KEY_RESTRICTED => { code: "R422-INTEGRATION-005", status: :unprocessable_content }
    }.freeze

    OPEN_TIMEOUT_SECONDS = 5
    READ_TIMEOUT_SECONDS = 15

    # I guasti che non sono nostri: il fornitore non risponde, non si raggiunge, o chiude a metà.
    # `IOError` copre anche `EOFError` (connessione chiusa mentre leggevamo la risposta) e
    # `Net::HTTPBadResponse` è la riga di stato malformata: senza, un fornitore che tronca la
    # risposta uscirebbe come 500 dell'applicazione invece che come «riprova».
    TRANSPORT_ERRORS = [
      Net::OpenTimeout, Net::ReadTimeout, Timeout::Error, Net::HTTPBadResponse,
      SystemCallError, SocketError, OpenSSL::SSL::SSLError, IOError
    ].freeze

    # Le ragioni strutturate che Google mette in `error.details[].reason`. Si guardano QUESTE e non
    # il messaggio: il messaggio è testo per umani e cambia, la ragione è un contratto.
    #
    # Il problema della chiave si riconosce dal PREFISSO, non da un elenco chiuso: oltre a
    # `API_KEY_INVALID` esistono almeno `API_KEY_EXPIRED`, `API_KEY_NOT_FOUND` e i vari
    # `API_KEY_*_BLOCKED` delle restrizioni, e Google può aggiungerne. Con un elenco chiuso ogni
    # ragione non prevista finirebbe fra i «tutto a posto» — una chiave scaduta marcata verificata.
    GOOGLE_KEY_PREFIX = "API_KEY_"
    GOOGLE_DISABLED = %w[SERVICE_DISABLED SERVICE_NOT_ACTIVATED ACCESS_TOKEN_SCOPE_INSUFFICIENT].freeze
    # `API_KEY_SERVICE_BLOCKED`, `API_KEY_HTTP_REFERRER_BLOCKED`, `API_KEY_IP_ADDRESS_BLOCKED`,
    # `API_KEY_ANDROID_APP_BLOCKED`, `API_KEY_IOS_APP_BLOCKED`: la chiave ESISTE ed è valida, sono le
    # restrizioni che le abbiamo messo sopra a non lasciarla passare. Non è «ricopiala» e non è
    # «accendi il servizio»: è «allarga le restrizioni della chiave». Terzo posto, terzo messaggio —
    # dire uno degli altri due manderebbe la persona a fare una cosa che non risolve.
    GOOGLE_RESTRICTED = /\AAPI_KEY_[A-Z_]+_BLOCKED\z/
    # Il messaggio è testo per umani e NON è un contratto: infatti non decide mai da solo e non viene
    # MAI salvato — può contenere pezzi della richiesta, e la richiesta contiene la chiave. Si legge
    # in memoria e muore in memoria, per il solo scopo di NON dichiarare buona una chiave su un
    # rifiuto che la nomina.
    GOOGLE_KEY_IN_MESSAGE = /api\s*key/i

    # Un indirizzo che il servizio PageSpeed rifiuta di suo: serve a farsi dire se la CHIAVE passa il
    # cancello senza far girare un'analisi vera, che costerebbe quaranta secondi a ogni salvataggio.
    # Il cancello delle chiavi sta PRIMA della validazione della richiesta (verificato: con una URL
    # perfettamente valida e una chiave inventata la risposta è comunque API_KEY_INVALID).
    PAGESPEED_PROBE_URL = "not-a-url"

    # Come si prova ciascun fornitore. Mappa costante e non `case` perché deve avere esattamente le
    # stesse chiavi del registro, e così una spec può dirlo: un servizio collegabile ma non
    # verificabile riporterebbe al mistero silenzioso da cui questa lavorazione vuole uscire, e con un
    # `case` la verifica di quella parità è impossibile da scrivere senza fingere.
    PROBES = {
      "pagespeed" => :verify_pagespeed
    }.freeze

    def initialize(provider:, api_key:)
      @provider = provider.to_s
      @api_key = api_key.to_s
    end

    # → Result.ok(nil) se la chiave va bene, Result.err(AppError) altrimenti.
    def call
      probe = PROBES[@provider]
      # Il fornitore sconosciuto si distingue PRIMA della chiave vuota: sono due guasti diversi, e
      # confonderli renderebbe cieca la spec che tiene allineati registro e verifica.
      return failure(UPSTREAM_ERROR) if probe.nil?
      return failure(INVALID_KEY) if @api_key.blank?

      send(probe)
    end

    private

    def failure(outcome)
      spec = OUTCOMES.fetch(outcome)
      Result.err(AppError.new(I18n.t("integrations.errors.#{outcome}"),
                              code: spec[:code], status: spec[:status], details: { outcome: outcome }))
    end

    # La sonda manda apposta un indirizzo sbagliato, quindi qui il 400 è l'esito ATTESO di una chiave
    # buona: il cancello delle chiavi sta prima della validazione della richiesta.
    #
    # Qui la chiave resta nella query perché è così che la manda `Seo::PageSpeed::Client`: la sonda
    # deve provare la STESSA porta che useranno le chiamate vere. Spostarla nell'header è lavoro di
    # quel client, non di questa sonda.
    def verify_pagespeed
      base = "#{Seo::PageSpeed::Constants::BASE_URL}#{Seo::PageSpeed::Constants::PATH}"
      uri = URI.parse("#{base}?url=#{CGI.escape(PAGESPEED_PROBE_URL)}&key=#{CGI.escape(@api_key)}")
      verify_google(uri, headers: {}, bad_request_means_ok: true)
    end

    def verify_google(uri, headers:, bad_request_means_ok:)
      response = get(uri, headers)
      code = response.code.to_i
      return Result.ok(nil) if code.between?(200, 299)

      reason = google_reason(response.body)
      return failure(SERVICE_DISABLED) if GOOGLE_DISABLED.include?(reason)
      # La restrizione si riconosce PRIMA del prefisso generico, o quello la assorbirebbe fra le
      # chiavi sbagliate insieme al consiglio inutile di ricopiarla.
      return failure(KEY_RESTRICTED) if reason&.match?(GOOGLE_RESTRICTED)
      return failure(INVALID_KEY) if reason&.start_with?(GOOGLE_KEY_PREFIX)
      return failure(INVALID_KEY) if code.in?([ 401, 403 ])

      # Il 400 vale «la chiave è passata» SOLO se a rifiutare è riconoscibilmente Google: la sonda
      # manda un indirizzo storto apposta e si aspetta il rifiuto DI GOOGLE. Un 400 che non sappiamo
      # leggere — la pagina HTML di un proxy aziendale in mezzo, un portale captive — non dice niente
      # sulla chiave, e prenderlo per buono segnerebbe come verificata una credenziale mai arrivata.
      if bad_request_means_ok && code == 400 && google_error?(response.body)
        # Ultima rete, e tira in UNA SOLA direzione: può togliere un «va bene», mai darlo. Serve
        # perché qui il rifiuto è l'esito atteso, quindi è l'unico punto dove un problema della
        # chiave può passare inosservato — e la ragione strutturata Google non la manda sempre.
        return failure(INVALID_KEY) if google_mentions_key?(response.body)

        return Result.ok(nil)
      end

      failure(UPSTREAM_ERROR)
    rescue *TRANSPORT_ERRORS
      failure(UNREACHABLE)
    end

    # Il gateway non ha un endpoint che dica solo «questa chiave è buona»: la prova più piccola è una
    # richiesta da un token. E si ferma all'ACCETTAZIONE — se il gateway prende in carico il lavoro,
    # la chiave ha già passato il cancello, e cosa risponderà l'LLM non ci riguarda.
    #
    # `max_poll_attempts: 0` è il modo di dirlo al client: con zero giri non interroga mai il lavoro e
    # solleva subito il codice «accettato ma non finito», che qui è un sì. Con anche un solo giro,
    # invece, un lavoro che fallisce o tarda farebbe risultare rotta una chiave perfetta — e il guasto
    # dell'LLM diventerebbe un problema di credenziali.
    #
    # Si rescue il TRASPORTO, non `StandardError`: un errore di programmazione qui dentro deve
    # esplodere e finire nel monitoraggio, non travestirsi da «fornitore irraggiungibile». È
    # esattamente il travestimento che in questo prodotto ha già tenuto spente funzioni intere senza
    # che nessuno se ne accorgesse.
    # Si guarda il CODICE dell'errore, non `status`.
    #
    # `status` è il simbolo Rack con cui il client risponde al browser, e vale `:bad_gateway` ANCHE
    # per un 401: leggendo quello, una chiave rifiutata diventava «il fornitore ha un guasto» — cioè
    # il contrario di ciò che questo servizio esiste per dire. Il codice invece distingue.
    # Il corpo di un errore Google, o nil se non lo è. JSON valido non vuol dire forma attesa: `null`,
    # un array o una stringa sono tutti JSON legittimi, e su quelli `dig` solleva. Qui non deve
    # sollevare niente — una risposta storta è un esito, non un guasto del nostro codice.
    def google_error_body(body)
      parsed = JSON.parse(body.to_s)
      return nil unless parsed.is_a?(Hash)

      error = parsed["error"]
      error.is_a?(Hash) ? error : nil
    rescue JSON::ParserError
      nil
    end

    def google_error?(body) = google_error_body(body).present?

    def google_mentions_key?(body)
      message = google_error_body(body)&.fetch("message", nil)
      message.is_a?(String) && message.match?(GOOGLE_KEY_IN_MESSAGE)
    end

    # Solo una ragione che sia davvero una stringa: su un `reason` numerico o annidato `start_with?`
    # solleverebbe, e una risposta storta del fornitore diventerebbe un guasto del nostro codice.
    def google_reason(body)
      details = google_error_body(body)&.fetch("details", nil)
      return nil unless details.is_a?(Array)

      details.filter_map { |item| item["reason"] if item.is_a?(Hash) && item["reason"].is_a?(String) }.first
    end

    def get(uri, headers)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = OPEN_TIMEOUT_SECONDS
      http.read_timeout = READ_TIMEOUT_SECONDS

      request = Net::HTTP::Get.new(uri)
      request["Accept"] = "application/json"
      headers.each { |name, value| request[name] = value }
      http.request(request)
    end
  end
end
