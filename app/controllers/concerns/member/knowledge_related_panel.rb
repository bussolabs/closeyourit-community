# frozen_string_literal: true

module Member
  # Azione JSON del pannello «Conoscenza correlata», condivisa dalla show del ticket e da quella del
  # gruppo errori: stesse pagine, stesso payload, stesso motivo del collegamento (CYRA-414 — prima
  # erano due copie identiche che potevano divergere). Il controller che lo include implementa
  # `knowledge_related_record` e resta padrone dei propri before_action (scoping e anti-BOLA).
  module KnowledgeRelatedPanel
    # Pagine Knowledge correlate al record (JSON, pannello lazy nella show). Lettura baseline: chi
    # vede il record vede la conoscenza del suo progetto. Errori → envelope standard: il JS mostra
    # il vuoto, mai un errore utente.
    def knowledge
      result = ::Knowledge::FindRelatedPages.call(record: knowledge_related_record)
      if result.ok?
        render json: { data: { pages: result.value.map { |row| knowledge_payload(row) } } }
      else
        render json: { error: { code: result.error.code, message: result.error.message } },
               status: result.error.status
      end
    end

    private

    # Payload minimale: il pannello è compatto (titolo, tipo, motivo, link).
    def knowledge_payload(row)
      page = row.page
      { id: page.id, title: page.title, kind: page.kind,
        kind_label: t("member.knowledge.kind.#{page.kind}"),
        reason: knowledge_reason(row.reason), url: member_knowledge_page_path(page) }
    end

    # Il motivo arriva già in parole all'utente: il JS non traduce nulla.
    def knowledge_reason(reason)
      if reason.terms.any?
        t("member.knowledge.related.reason_terms", terms: reason.terms.join(", "))
      else
        t("member.knowledge.related.reason_section", section: reason.section)
      end
    end
  end
end
