# frozen_string_literal: true

require "rails_helper"

# CYRA-667 — il nome dell'autore e' un'istantanea presa alla creazione (snapshot_author_name) e non si
# riscrive mai (attr_readonly, che con load_defaults 8.1 solleva anche su update_column): un resoconto
# resta fedele a com'era anche se l'account cambia nome o sparisce.
#
# I tre rami del fallback si provano su oggetti costruiti in memoria: al serializzatore non serve una
# riga salvata, e le righe scritte prima che il congelamento esistesse non sono piu' producibili
# passando dalle validazioni.
RSpec.describe ReportSerializer do
  def reso(report) = JSON.parse(described_class.new(report).to_json)

  it "usa il nome congelato alla creazione, non quello che l'account ha adesso" do
    report = create(:ticket_report)
    nome_di_allora = report.author_name
    report.author.update!(name: "Nome cambiato dopo")

    expect(nome_di_allora).to be_present
    expect(reso(report.reload)["author"]).to eq(nome_di_allora)
  end

  it "sulle righe vecchie senza istantanea ricade sull'account" do
    account = create(:account, name: "Chi ha scritto")
    report = Ticketing::Report.new(author_name: nil, author: account, body: "x", version: 1)

    expect(reso(report)["author"]).to eq("Chi ha scritto")
  end

  it "con l'istantanea vuota ricade comunque sull'account" do
    account = create(:account, name: "Chi ha scritto")
    report = Ticketing::Report.new(author_name: "", author: account, body: "x", version: 1)

    expect(reso(report)["author"]).to eq("Chi ha scritto")
  end

  it "senza istantanea e senza account non esplode" do
    report = Ticketing::Report.new(author_name: nil, author: nil, body: "x", version: 1)

    expect(reso(report)["author"]).to be_nil
  end

  it "porta i campi del resoconto" do
    report = create(:ticket_report)

    expect(reso(report).keys).to include("id", "ticket_id", "version", "body", "source", "created_at")
  end
end
