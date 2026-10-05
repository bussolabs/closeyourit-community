# frozen_string_literal: true

module Knowledge
  module Pages
    # Guardie comuni ai tre passaggi della revisione (CYRA-298): accettare, scartare, segnare come
    # scritta su file. Sono le stesse due domande ogni volta — «la pagina è nello stato giusto?» e
    # «chi agisce la può gestire?» — e vivono qui perché una risposta diversa fra i tre passaggi
    # sarebbe un buco: accettare senza poter modificare varrebbe come modificare.
    #
    # L'autorizzazione è quella di sempre (Knowledge::PageManageable, chiave knowledge.edit): niente
    # chiave RBAC nuova, chi già gestisce la pagina decide anche se tenerla.
    #
    # human_actor?/machine_decision (CYRA-642): accettare e scartare sono gesti di una PERSONA, e il
    # permesso da solo non lo garantisce — un Accounts::Account kind :service con `knowledge.edit` è
    # autorizzato quanto un owner. La coda di revisione esiste apposta perché quello che un assistente
    # propone lo rilegga qualcuno prima che entri in ricerca, RAG e correlate: una macchina che
    # decidesse la svuoterebbe da sola, per giunta approvando ciò che ha appena scritto (PageManageable
    # dà via libera all'AUTORE della pagina, e l'autore delle proposte è per costruzione l'assistente).
    # Il guard sta QUI e non nei controller perché i canali che decidono sono due — la pagina di
    # revisione nel web e `cyi kb approve/reject` dal terminale — e il secondo è la porta vera: un
    # account di servizio non fa login web (Auth::SessionsController esige `human?`) ma il suo token
    # `cyi_u_` si autentica come quello di una persona (UserTokenAuthentication non guarda `kind`).
    # Fail-closed: attore assente = non umano.
    #
    # Vale per Approve/Reject, NON per MarkConsolidated: segnare una pagina come scritta fra i
    # documenti versionati è un passo MECCANICO, lo compie la stessa automazione che archivia il file
    # nel repo. Sono tre passaggi distinti e solo i primi due sono una decisione.
    module ReviewGuards
      private

      def manageable?
        Knowledge::PageManageable.call(page: @page, actor: @actor)
      end

      def human_actor?
        @actor.present? && @actor.human?
      end

      def machine_decision
        Result.err(
          AppError.new(
            I18n.t("member.knowledge.errors.review_machine"),
            code: "R403-KNOWLEDGE-005",
            status: :forbidden
          )
        )
      end

      def forbidden
        Result.err(
          AppError.new(
            I18n.t("member.knowledge.errors.review_forbidden"),
            code: "R403-KNOWLEDGE-004",
            status: :forbidden
          )
        )
      end

      # Transizione chiesta da uno stato che non la ammette (accettare una pagina già pubblicata,
      # consolidarne una ancora in revisione): 422, non 404 — la pagina esiste ed è visibile.
      def wrong_status(key)
        Result.err(
          AppError.new(I18n.t("member.knowledge.errors.#{key}"), code: "R422-KNOWLEDGE-009")
        )
      end
    end
  end
end
