# frozen_string_literal: true

module Uptime
  # Il codice da COPIARE per mostrare la status page (o il badge) su un altro sito. Lo snippet è testo
  # da leggere, non markup da eseguire: esce come String normale, mai html_safe (CYRA-742).
  module EmbedHelper
    # Lingua da inchiodare negli URL degli snippet, così il sito di destinazione mostra lo stato nella
    # stessa lingua di chi ha copiato il codice. `nil` sul default → nessun parametro nell'URL.
    def status_embed_locale = I18n.locale == I18n.default_locale ? nil : I18n.locale

    # Variante dell'URL pubblico da mettere DENTRO lo snippet. Solo lì: il link pubblico che si copia e
    # si condivide resta param-free com'era. Il locale viene da `I18n.locale` (già whitelistato), mai
    # da un parametro grezzo, quindi l'interpolazione non è una via d'ingresso.
    def status_embed_url(url)
      locale = status_embed_locale
      return url if locale.nil?

      "#{url}#{url.include?('?') ? '&' : '?'}locale=#{locale}"
    end

    # Snippet iframe da consegnare a chi vuole mostrare la status page (o il badge) sul proprio sito.
    # Ritorna una String NORMALE, non `html_safe`: nel `<code>` dev'essere ESCAPATA e leggibile come
    # testo — è il codice da copiare, non markup da eseguire. `clipboard#copy` legge `textContent`,
    # quindi negli appunti finisce comunque l'HTML vero.
    def status_embed_snippet(url, width:, height:, title:)
      %(<iframe src="#{url}" width="#{width}" height="#{height}" title="#{title}" ) +
        %(style="border:0" loading="lazy"></iframe>)
    end
  end
end
