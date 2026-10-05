# frozen_string_literal: true

module Ops
  # L'unica email che il prodotto manda a se stesso: la prova di spedizione di CYRA-233.
  #
  # Eredita da ApplicationMailer apposta — deve partire dallo STESSO mittente delle email vere, o non
  # proverebbe niente sul dominio che si vuole verificare. Il corpo è passato come testo e non da una
  # view: nessun destinatario umano la legge come parte del prodotto, e una view in più sarebbe una
  # traduzione in più da tenere allineata per una diagnostica di ops.
  class ProbeMailer < ApplicationMailer
    # Argomenti POSIZIONALI come ogni altro mailer del repo: ApplicationMailer#process avvolge l'azione
    # con `*args` per localizzarla sul destinatario, e dei keyword arriverebbero all'azione come hash
    # posizionale (ArgumentError). Il primo argomento non è un Account: la lingua resta quella di default,
    # che per un'email di diagnostica va benissimo.
    def probe(to, subject, body)
      mail(to: to, subject: subject, body: body)
    end
  end
end
