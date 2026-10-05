# frozen_string_literal: true

module Ops
  # Manda UNA email di prova al destinatario indicato, dal mittente reale del prodotto (CYRA-233).
  #
  # Ops::MailSenderCheck chiede al fornitore se il dominio risulta verificato; questo invece spedisce
  # davvero. Le due cose non si sostituiscono: un dominio verificato con la chiave sbagliata, o un
  # fornitore che accetta e poi scarta, danno verde al primo controllo e nessuna email nella casella.
  # La prima voce della Definition of Done («un'email di prova parte e arriva davvero al destinatario»)
  # si chiude solo qui, e nessun controllo automatico può chiuderla al posto di una persona che guarda
  # la propria posta.
  #
  # `deliver_now` e non `deliver_later`: chi lancia la prova vuole l'esito adesso: dentro un job il
  # rifiuto tornerebbe a essere un job fallito che nessuno legge — cioè il guasto di partenza.
  # Si usa dalla riga di comando: bin/rails "ops:mail_test[persona@esempio.it]".
  class SendTestEmail < ApplicationService
    def initialize(to:)
      @to = to.to_s.strip
    end

    def call
      return Result.err(invalid_recipient) unless valid_recipient?

      Ops::ProbeMailer.probe(@to, "CloseYourIt — email di prova (#{Rails.env})", body).deliver_now

      Result.ok({ to: @to, from: ApplicationMailer.default[:from] })
    rescue StandardError => e
      # Il messaggio del fornitore («domain is not verified», chiave rifiutata, destinatario in
      # soppressione) È l'informazione cercata: torna leggibile invece che come stack trace.
      Result.err(AppError.new("Spedizione rifiutata: #{e.class}: #{e.message}",
                              code: "R502-MAIL-001", status: :bad_gateway))
    end

    private

    # `Mail::Address` accetta anche una stringa senza chiocciola (la tratta come mailbox locale): serve
    # anche il dominio, o la prova partirebbe verso un indirizzo che non esiste.
    def valid_recipient?
      return false if @to.blank?

      Mail::Address.new(@to).domain.present?
    rescue StandardError
      false
    end

    def invalid_recipient
      AppError.new("Destinatario non valido: #{@to.inspect}", code: "R422-MAIL-001")
    end

    def body
      <<~TEXT
        Questa è un'email di prova di CloseYourIt (ambiente #{Rails.env}).

        Mittente: #{ApplicationMailer.default[:from]}
        Inviata il: #{Time.current.strftime("%d/%m/%Y %H:%M %Z")}

        Se l'hai ricevuta, la spedizione funziona: avvisi, riepiloghi, inviti e reimpostazione
        password possono arrivare.
      TEXT
    end
  end
end
