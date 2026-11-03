# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::TicketRefComponent, type: :component do
  let(:ticket) { create(:ticket, title: "The invoice export drops the last row") }

  it "links to the ticket with its code, title and status badge" do
    render_inline(described_class.new(ticket:))

    link = page.find("a[data-test='ticket-ref']")
    expect(link[:href]).to eq("/member/tickets/#{ticket.to_param}")
    expect(link).to have_css(".font-mono", text: ticket.code)
    expect(link).to have_text("The invoice export drops the last row")
    expect(link).to have_text(ticket.status.display_label)
  end

  it "shortens a long title and keeps the full one as a tooltip" do
    ticket.title = "A" * 80
    render_inline(described_class.new(ticket:))

    link = page.find("a[data-test='ticket-ref']")
    expect(link[:title]).to eq("A" * 80)
    expect(link).not_to have_text("A" * 80)
  end
end
