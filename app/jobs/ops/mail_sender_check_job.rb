# frozen_string_literal: true

module Ops
  # Giro giornaliero (recurring.yml) che verifica se il mittente di TUTTE le email è ancora abilitato a
  # spedire, e lo lascia scritto nei log quando non lo è (CYRA-233).
  #
  # Perché nei log e non via avviso: il canale guasto è proprio l'email, e un avviso che deve passare da
  # lì non arriverebbe mai — sarebbe la stessa promessa non mantenuta che ha aperto il ticket. Il WARN/
  # ERROR di Rails viene raccolto dal self-monitoring (capture_rails_logs_min_level = :warn in
  # config/initializers/closeyourit.rb), quindi il segnale esiste anche senza che nessuno legga i log a
  # mano. Lo stesso controllo è mostrato su /valhalla/health (Valhalla::ProbeServices).
  #
  # Sola osservazione: non spedisce niente, non ripara, non solleva (il controllo cattura tutto
  # internamente, così un guasto del fornitore non fa ritentare il giro a vuoto).
  class MailSenderCheckJob < ApplicationJob
    queue_as :maintenance

    def perform
      result = Ops::MailSenderCheck.call
      return if result.deliverable?

      # Fornitore muto ≠ mittente rotto: dello stato del mittente non sappiamo niente, e gridare per un
      # guasto di rete passeggero è il modo più rapido per far ignorare gli allarmi veri. Vale anche
      # per la chiave che può spedire ma non leggere l'elenco domini (CYRA-771): lì è il controllo a
      # essere cieco, non il mittente a essere rotto.
      return log_restricted_key(result) if result.status == :restricted_key
      return log_provider_unreachable(result) if result.status == :error

      Rails.logger.error(
        "Ops::MailSenderCheckJob il mittente #{result.from} non è abilitato a spedire " \
        "(#{result.status}): #{result.detail} — nessuna email può partire: avvisi, riepiloghi, inviti e " \
        "reimpostazione password non arrivano a nessuno."
      )
    end

    private

    # A differenza del fornitore muto questo non passa da sé: finché la chiave resta ristretta il
    # controllo non saprà mai dire se il mittente spedisce. Il rimedio sta nella riga, altrimenti il
    # WARN quotidiano racconta un guasto senza dire cosa farne.
    #
    # La riga NON promette che le email partano: da una chiave abilitata al solo invio non si deduce
    # che il dominio del mittente sia verificato: sono due cose che il fornitore tiene separate. Ciò
    # che sappiamo è di non sapere, e scrivere altro rimetterebbe in circolo la stessa sicurezza
    # falsa che il ticket è nato per togliere.
    def log_restricted_key(result)
      Rails.logger.warn(
        "Ops::MailSenderCheckJob impossibile verificare il mittente #{result.from}: #{result.detail} — " \
        "stato della spedizione ignoto, e resterà tale finché la chiave non avrà il permesso di " \
        "lettura sui domini."
      )
    end

    def log_provider_unreachable(result)
      Rails.logger.warn(
        "Ops::MailSenderCheckJob impossibile verificare il mittente #{result.from}: #{result.detail} — " \
        "stato della spedizione ignoto per questo giro."
      )
    end
  end
end
