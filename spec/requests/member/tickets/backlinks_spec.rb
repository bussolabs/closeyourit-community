# frozen_string_literal: true

require "rails_helper"

# CYRA-163 — Dagli errori collegati si arriva al ticket, e viceversa: backlink di sola lettura verso
# l'errore di origine (promozione) e i log collegati manualmente (Logs::Link).
RSpec.describe "Member ticket backlinks (error origin + linked logs)", type: :request do
  let(:org) { create(:organization, name: "Demo") }
  let!(:project) { create(:project, organization: org, name: "Storefront", key: "STR") }
  let!(:status) { create(:ticket_status, organization: org, code: "open", label: "Open", color: "amber") }
  let!(:priority) { create(:ticket_priority, organization: org, code: "medium", label: "Medium", color: "amber") }
  let(:ticket) { create(:ticket, organization: org, project: project, status: status, priority: priority) }

  let(:admin) do
    create(:account).tap { |account| create(:membership, account:, organization: org, role: :owner) }
  end

  before do
    post login_path, params: { email: admin.email, password: "Secret123!" }
  end

  def doc
    Nokogiri::HTML(response.body)
  end

  it "un ticket nato dalla promozione di un errore mostra il collegamento all'origine" do
    group = create(:error_group, project: project, title: "RuntimeError: boom", ticket: ticket)

    get member_ticket_path(ticket)

    expect(doc.at_css("[data-test='ticket-error-origin']").text).to include("RuntimeError: boom")
    origine = doc.at_css("[data-test='ticket-error-origin-link']")["href"]

    # Seconda richiesta nello stesso esempio: le query di layout si ripetono per pagina e non sono
    # un N+1 di produzione.
    allow_n_plus_one { get origine }

    expect(response.body).to include('data-test="member-error-group"')
    expect(response.body).to include(group.title)
  end

  it "un ticket creato a mano non mostra il pannello di origine" do
    get member_ticket_path(ticket)

    expect(doc.at_css("[data-test='ticket-error-origin']")).to be_nil
  end

  it "mostra i log collegati manualmente e il link porta alla pagina del log" do
    entry = create(:log_entry, project: project, message: "checkout timeout")
    create(:log_link, log_entry: entry, linkable: ticket)

    get member_ticket_path(ticket)

    expect(doc.at_css("[data-test='linked-log-entries']").text).to include("checkout timeout")
    riga = doc.at_css("[data-test='linked-log-entry-#{entry.id}']")["href"]

    allow_n_plus_one { get riga }

    expect(response.body).to include('data-test="member-log-entry"')
  end

  # CYRA-883 — on the ticket an empty linked-logs block is left out; the error group page keeps it.
  it "hides the linked logs block when nothing is linked" do
    get member_ticket_path(ticket)

    expect(response.body).not_to include('data-test="linked-log-entries"')
  end
end
