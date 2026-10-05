# frozen_string_literal: true

module Ops
  # Il mittente configurato è davvero abilitato a spedire? (CYRA-233)
  #
  # Ogni email del prodotto — avvisi, riepiloghi, inviti, reimpostazione password — parte dal `from` di
  # ApplicationMailer. Resend rifiuta la spedizione da un dominio che non risulta verificato nel proprio
  # account, e il rifiuto NON si vede da nessuna parte: l'invio è dentro un job, il fallimento resta un
  # job fallito fra gli altri, e il destinatario semplicemente non riceve niente. È rimasto così finché
  # non l'ha notato una persona a mano — il percorso «qualcosa si rompe → arriva l'avviso» era interrotto
  # proprio nel tratto che avrebbe dovuto avvisare.
  #
  # Questo controllo chiude l'anello: interroga l'elenco domini del fornitore e confronta col dominio del
  # mittente reale. Sola OSSERVAZIONE — non manda email (sarebbe il canale rotto a doversi denunciare da
  # solo), non spedisce niente di prova, non ripara. Chi lo chiama ne fa un segnale:
  # Ops::MailSenderCheckJob lo lascia nei log, Valhalla::ProbeServices lo mostra su /valhalla/health.
  #
  # Non solleva MAI: il chiamante è un giro ricorrente, e un'eccezione lo farebbe ritentare a vuoto
  # trasformando un guasto del fornitore in rumore nella coda.
  class MailSenderCheck < ApplicationService
    # verified   → il dominio del mittente è verificato: le email possono partire.
    # unverified → dominio presente ma non verificato (record DNS mancanti o non ancora propagati).
    # unknown_domain → il dominio non risulta affatto all'elenco: è il guasto di CYRA-233.
    # unconfigured   → nessuna chiave del fornitore. In produzione l'app spegne l'invio
    #                  (config/environments/production.rb): non parte una mail nemmeno col DNS perfetto.
    # invalid_sender → il mittente configurato non è un indirizzo email leggibile.
    # error          → il fornitore non risponde: lo stato del mittente resta ignoto.
    # restricted_key → il fornitore RIFIUTA la lettura: la chiave è abilitata al solo invio (CYRA-771).
    #                  Lo stato del mittente resta ignoto, e il rifiuto non dice niente su di esso.
    Result = Data.define(:status, :from, :domain, :detail) do
      def deliverable? = status == :verified

      # «Non posso controllare» non è «il mittente non spedisce» (CYRA-771). In produzione i due casi
      # finivano nello stesso rosso: la chiave abilitata al solo invio faceva fallire la lettura, il
      # rescue la traduceva in :error e la scheda salute mostrava la posta giù mentre le email
      # partivano davvero. Un allarme che grida al lupo insegna a ignorare quelli veri.
      #
      # Solo :restricted_key, MAI :error: il rifiuto è una risposta esplicita e circoscritta del
      # fornitore, mentre :error è il cesto di tutto ciò che non sappiamo — dentro c'è il timeout di
      # rete passeggero ma anche la chiave revocata o invalida, che ferma DAVVERO la spedizione
      # perché è la stessa che usa ApplicationMailer. Chiamare «non lo so» anche quello nasconderebbe
      # un guasto vero dietro un colore tranquillo, cioè il difetto di questo ticket al contrario.
      def unverifiable? = status == :restricted_key
    end

    # Lo status che Resend considera buono per spedire. Gli altri (`pending`, `failed`,
    # `temporary_failure`, `not_started`) valgono tutti «oggi non spedisce».
    VERIFIED = "verified"

    # Nessun argomento = il mittente che useranno DAVVERO le email. Non rilegge MAIL_FROM per conto suo:
    # il default di ApplicationMailer è già quel valore (o il fallback), e leggere da due posti diversi
    # è il modo per controllare un mittente e spedirne un altro.
    def initialize(from: ApplicationMailer.default[:from])
      @from = from.to_s
    end

    def call
      domain = sender_domain
      return result(:invalid_sender, nil, "mittente non interpretabile come indirizzo: #{@from.inspect}") if domain.blank?

      # `Resend.api_key` e non ENV: è il valore che userebbe la spedizione vera (lo imposta
      # config/initializers/resend.rb dalla stessa variabile che decide `perform_deliveries`).
      return result(:unconfigured, domain, "nessuna chiave del fornitore: l'invio è spento") if Resend.api_key.blank?

      entry = find_domain(domain)
      return result(:unknown_domain, domain, "il dominio #{domain} non risulta fra quelli configurati presso il fornitore") if entry.nil?

      status = entry_status(entry)
      return result(:verified, domain, nil) if status == VERIFIED

      result(:unverified, domain, "il dominio #{domain} risulta in stato #{status.presence || "sconosciuto"}, non verificato")
    rescue StandardError => e
      return restricted_key_result if restricted_key?(e)

      # Il messaggio del fornitore può citare la richiesta ma mai la chiave (viaggia in un header, che
      # non finisce nel messaggio d'errore della gem): resta comunque solo classe + messaggio.
      result(:error, sender_domain, "#{e.class}: #{e.message}")
    end

    private

    # Si riconosce dal MESSAGGIO perché la gem non lascia altro: `Resend::Error` espone soltanto
    # `headers` (nessun lettore per il codice HTTP) e mappa 400, 401 e 422 tutti sulla stessa
    # InvalidRequestError, quindi la classe non distingue «non ti è permesso» da «richiesta
    # sbagliata». Il nome dell'errore (`restricted_api_key`) arriva nel corpo ma la gem lo scarta:
    # tiene solo `message`. Il testo è quello documentato, e un fornitore che lo riscrivesse
    # riporterebbe il caso su :error — stesso colore neutro, dettaglio meno esplicito.
    RESTRICTED_KEY_MESSAGE = /restricted to only send/i

    def restricted_key?(error) = error.message.to_s.match?(RESTRICTED_KEY_MESSAGE)

    def restricted_key_result
      result(:restricted_key, sender_domain,
             "la chiave del fornitore è abilitata al solo invio: l'elenco dei domini non le è " \
             "accessibile, lo stato del mittente resta ignoto")
    end

    # `Mail::Address` è il parser che usa ActionMailer stesso, quindi legge esattamente ciò che leggerà
    # la spedizione: nome visualizzato, commenti fra parentesi (il mittente di staging ne ha uno),
    # indirizzo nudo. Un valore non interpretabile solleva: qui diventa `nil` e più su :invalid_sender.
    def sender_domain
      Mail::Address.new(@from).domain.presence
    rescue StandardError
      nil
    end

    # Match ESATTO sul nome del dominio: Resend spedisce dal dominio registrato, non dai suoi
    # sottodomini (`notifications.esempio.it` va aggiunto a parte anche se `esempio.it` è verificato).
    # Accettare il padre darebbe un verde falso, cioè di nuovo il silenzio che ha lasciato passare
    # CYRA-233: meglio un allarme di troppo che un allarme mancato.
    def find_domain(domain)
      Array(Resend::Domains.list[:data]).find { |entry| entry_name(entry).casecmp?(domain) }
    end

    # La gem simbolizza solo le chiavi di PRIMO livello della risposta: dentro `data` restano stringhe.
    # Le voci sono lette con entrambe le forme perché un domani la gem potrebbe simbolizzare in profondità.
    def entry_name(entry) = (entry["name"] || entry[:name]).to_s
    def entry_status(entry) = (entry["status"] || entry[:status]).to_s

    def result(status, domain, detail) = Result.new(status:, from: @from, domain:, detail:)
  end
end
