# frozen_string_literal: true

module Embeddings
  # Controllo periodico (recurring.yml, ogni 5 minuti) che il servizio di embedding risponda.
  #
  # Perché serve (CYEM-2): ricerca semantica, collegamento fra errori/ticket/pagine e deduplica
  # degradano IN SILENZIO quando il servizio è giù — è una scelta di progetto esplicita in
  # Embeddings::EmbedText, e va bene per l'utente, che non deve vedere errori tecnici. Il costo è
  # che nessuno se ne accorge: è già capitato, ed è durato un giorno e mezzo prima che qualcuno
  # notasse a mano.
  #
  # Perché passa da EmbedText e non da un ping al servizio: la smoke esistente (bin/smoke del repo
  # embedding) gira DENTRO il container e prova solo che il servizio parli a se stesso, quindi non
  # può accorgersi che il guasto sta nel percorso fra chi chiede e chi risponde — che è esattamente
  # com'è andata (il redeploy di Rails cambiava il nome del container e spezzava la rotta). Qui si
  # esce dalla stessa porta delle feature vere: stesso EMBED_BASE_URL, stesso client, stesso errore.
  # Nemmeno Uptime può farlo: Uptime::Ping rifiuta gli indirizzi privati, e il servizio vive sulla
  # rete interna.
  class CheckServiceHealthJob < ApplicationJob
    queue_as :maintenance

    # Testo minimo: l'esito interessa, il vettore no. Non tocca il DB e non finisce in nessun indice.
    PROBE_TEXT = "healthcheck"

    def perform
      # Spegnere gli embedding è una scelta, non un guasto: avvisare per una funzione disattivata
      # di proposito è il modo più rapido per far ignorare gli avvisi veri.
      return if Ai::Feature.disabled?(:embeddings)

      result = Embeddings::EmbedText.call(text: PROBE_TEXT)
      return if result.ok?

      error = result.error
      Rails.logger.error(
        "Embeddings::CheckServiceHealthJob il servizio di embedding non risponde " \
        "(#{error.code}): #{error.message} — ricerca semantica, collegamenti e deduplica " \
        "stanno degradando in silenzio"
      )

      notify(error)
    end

    private

    # A platform alert: it reaches only the gods (CYRA-875).
    def notify(error) = Alerting::PlatformAlert.notify(event_type: "embedding_down", value: error.code)
  end
end
