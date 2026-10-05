# frozen_string_literal: true

require "rails_helper"

# CYRA-346 — per collegare un messaggio a un errore o a un ticket si apriva una tendina con decine di
# ticket identificati dal solo codice e errori troncati a metà frase, dove due voci diverse
# risultavano identiche: la funzione c'era ma non si poteva usare.
RSpec.describe "Member::Monitoring::LogEntries — collegamenti (CYRA-346)", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:entry) { create(:log_entry, project: project, occurred_at: 2.hours.ago) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  it "ogni ticket mostra il titolo accanto al codice" do
    ticket = create(:ticket, organization: org, project: project, title: "Il salvataggio va in errore")

    get member_monitoring_log_entry_path(entry)

    select = Nokogiri::HTML(response.body).at_css("[data-test='log-link-select-ticket']")
    expect(select).to be_present
    expect(select.text).to include(ticket.code).and include("Il salvataggio va in errore")
  end

  it "gli errori portano il titolo intero, non tagliato a metà frase" do
    lungo = "NoMethodError: undefined method 'name' for nil dentro il servizio di fatturazione mensile"
    create(:error_group, project: project, title: lungo)

    get member_monitoring_log_entry_path(entry)

    select = Nokogiri::HTML(response.body).at_css("[data-test='log-link-select-error']")
    expect(select.text).to include(lungo)
  end

  it "errori e ticket stanno in due sezioni distinte" do
    create(:error_group, project: project, title: "Un errore")
    create(:ticket, organization: org, project: project)

    get member_monitoring_log_entry_path(entry)

    doc = Nokogiri::HTML(response.body)
    expect(doc.at_css("[data-test='log-link-errors']")).to be_present
    expect(doc.at_css("[data-test='log-link-tickets']")).to be_present
  end

  it "in cima ci sono i candidati più vicini nel tempo a questo messaggio" do
    allow_n_plus_one do
      create(:error_group, project: project, title: "Vecchio", last_seen_at: 5.days.ago)
      create(:error_group, project: project, title: "Di poco fa", last_seen_at: entry.occurred_at + 5.minutes)
    end

    get member_monitoring_log_entry_path(entry)

    # La prima opzione è il placeholder (include_blank), i candidati vengono dopo.
    options = Nokogiri::HTML(response.body).css("[data-test='log-link-select-error'] option").map(&:text).compact_blank
    expect(options.second).to include("Di poco fa")
  end

  it "una famiglia senza candidati non mostra la sua tendina" do
    create(:error_group, project: project, title: "Solo errori")

    get member_monitoring_log_entry_path(entry)

    doc = Nokogiri::HTML(response.body)
    expect(doc.at_css("[data-test='log-link-errors']")).to be_present
    expect(doc.at_css("[data-test='log-link-tickets']")).to be_nil
  end
end
