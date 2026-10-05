# frozen_string_literal: true

module Authorization
  # CYRA-728 — il segno `dangerous` del catalogo diventa esecutivo.
  #
  # Fino a ieri quel flag serviva solo a disegnare un'icona nella pagina dei ruoli: dare i pieni
  # poteri a qualcuno, azzerare una password, sospendere un'organizzazione o cancellare un ruolo che
  # toglie i permessi a tutti partivano al primo click, e dalla riga di comando nemmeno quello.
  # Da qui in poi ogni richiesta che SCRIVE passando da una chiave pericolosa vuole una conferma
  # esplicita: il browser la manda dal dialogo, il terminale con il suo `--yes`.
  #
  # La regola sta in un service e non nei controller perché i canali sono due (area utenti e riga di
  # comando) e la risposta deve essere la stessa: due gemelli scritti a mano sono due politiche che
  # prima o poi divergono, e a divergere sarebbe proprio la parte che protegge le azioni peggiori.
  module DangerousAction
    # Il nome del parametro, uguale sui due canali: il dialogo web lo manda come campo nascosto, la
    # riga di comando come parametro della chiamata dietro il suo flag di conferma.
    CONFIRM_PARAM = :confirm

    # I verbi che non scrivono niente. Leggere non è eseguire: `secrets.read` è pericoloso perché
    # mostra valori riservati, ma la pagina che li elenca non si apre chiedendo «sei sicuro?» — la
    # conferma serve a fermare un'azione che parte, non una pagina che si guarda.
    SAFE_METHODS = %w[GET HEAD OPTIONS].freeze

    # I valori che sono un NO scritto. Tutto il resto, se c'è, è un sì.
    #
    # Non si tiene un elenco chiuso di sì per una ragione concreta: alcune pagine chiedono già una
    # conferma PIÙ forte sullo stesso parametro — scollegare una flotta di macchine vuole il nome del
    # codice ricopiato a mano (`confirm=fleet`), non un «sei sicuro?». Un elenco chiuso di sì
    # rifiuterebbe proprio la conferma più severa che il prodotto abbia, e chi la digita si vedrebbe
    # rispondere che non ha confermato. Il controller che pretende il nome continua a confrontarlo per
    # conto suo: qui si guarda solo se un gesto di conferma c'è stato.
    NEGATIONS = %w[0 false no off].freeze

    class << self
      # La richiesta va confermata? Chiave pericolosa del catalogo + verbo che scrive. Chiave
      # sconosciuta → false: nel dubbio non si pretende una conferma per un permesso che non c'è
      # (e che il Resolver nega comunque prima di arrivare qui).
      def confirmation_required?(key:, request_method:)
        return false if SAFE_METHODS.include?(request_method.to_s.upcase)

        Catalog.dangerous?(key)
      end

      def confirmed?(value)
        answer = value.to_s.strip
        answer.present? && NEGATIONS.exclude?(answer.downcase)
      end
    end
  end
end
