# frozen_string_literal: true

module Ui
  class PageHeaderComponentPreview < ViewComponent::Preview
    def title_only; end
    def with_back; end
    def with_actions; end
    def with_meta; end

    # Pallino "i" (Ui::TooltipComponent) accanto al titolo: spiega a cosa serve la pagina.
    def with_title_tooltip; end

    # Index: the one-crumb trail is hidden, actions sit beside the title, counts below (CYRA-883).
    def index_with_breadcrumb_and_counts; end

    # Show: breadcrumb Dashboard / Tickets / <item>, con azioni.
    def show_with_breadcrumb; end
  end
end
