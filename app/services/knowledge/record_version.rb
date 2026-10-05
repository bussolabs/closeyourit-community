# frozen_string_literal: true

module Knowledge
  # Congela uno snapshot immutabile della pagina KB corrente (Knowledge::Version). Va chiamato
  # DENTRO la transazione del service di mutazione (CreatePage/UpdatePage): o muta+snapshotta o
  # niente (una cronologia non perde versioni).
  #
  # Ritorna la Version creata (NON un Result): è un helper interno chiamato dagli altri service,
  # non dal controller — non deve inquinare il loro Result pattern. Se `create!` solleva (snapshot
  # invalido = bug), l'eccezione propaga e la transazione del chiamante fa rollback.
  # Pattern speculare a Ticketing::RecordActivity.
  class RecordVersion < ApplicationService
    def initialize(page:, author:)
      @page = page
      @author = author
    end

    def call
      Knowledge::Version.create!(
        page: @page,
        organization_id: @page.organization_id,
        number: next_number,
        title: @page.title,
        body: @page.body,
        tech_spec: @page.tech_spec,
        kind: @page.kind,
        created_by: @author,
        author_name: @author&.name
      )
    end

    private

    # Progressivo monotòno per pagina (l'indice unico [page_id, number] è la rete di sicurezza
    # contro edit concorrenti: una collisione fa rollback della transazione del chiamante).
    def next_number
      @page.versions.maximum(:number).to_i + 1
    end
  end
end
