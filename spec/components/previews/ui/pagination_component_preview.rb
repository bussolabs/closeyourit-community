# frozen_string_literal: true

module Ui
  class PaginationComponentPreview < ViewComponent::Preview
    # Una sola pagina: solo conteggio, nessun controllo.
    def single = render(Ui::PaginationComponent.new(pagination: result(page: 1, total: 18, total_pages: 1)))

    # Prima pagina di molte: prev disabilitato, numeri + ellissi, next attivo.
    def first_of_many = render(Ui::PaginationComponent.new(pagination: result(page: 1, total: 130, total_pages: 6)))

    # Pagina centrale: prev/next attivi, finestra centrata.
    def middle = render(Ui::PaginationComponent.new(pagination: result(page: 3, total: 130, total_pages: 6)))

    # Ultima pagina: next disabilitato.
    def last = render(Ui::PaginationComponent.new(pagination: result(page: 6, total: 130, total_pages: 6)))

    private

    def result(page:, total:, total_pages:)
      Pagination::Result.new(records: [], page: page, per: 25, total: total, total_pages: total_pages)
    end
  end
end
