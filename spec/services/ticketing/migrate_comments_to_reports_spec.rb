require "rails_helper"

RSpec.describe Ticketing::MigrateCommentsToReports do
  let(:organization) { create(:organization) }
  let(:ticket) { create(:ticket, organization: organization) }

  # `save!(validate: false)`: sono righe storiche, scritte prima che il tetto esistesse — è lo stato
  # in cui la migrazione le incontra in produzione.
  def comment(body, created_at: Time.current)
    build(:ticket_comment, organization: organization, ticket: ticket, body: body, created_at: created_at)
      .tap { |record| record.save!(validate: false) }
  end

  def long(text) = "#{text} #{"x" * 300}"

  it "sposta i commenti lunghi in versioni del resoconto, in ordine cronologico" do
    comment(long("Prima lavorazione."), created_at: 3.days.ago)
    comment(long("Risposta alla review."), created_at: 2.days.ago)
    comment(long("Correzione post-review."), created_at: 1.day.ago)

    described_class.call(ticket: ticket)

    expect(ticket.reports.chronological.map(&:version)).to eq([ 1, 2, 3 ])
    expect(ticket.reports.chronological.first.body).to start_with("Prima lavorazione.")
    expect(ticket.reports.chronological.last.body).to start_with("Correzione post-review.")
  end

  it "copia il corpo verbatim, senza toccare il commento" do
    original = comment(long("Fatto."))

    described_class.call(ticket: ticket)

    expect(ticket.reports.first.body).to eq(original.body)
    expect(original.reload.body).to eq(original.body)
    expect(original.compacted_at).to be_nil
  end

  it "conserva autore e data del commento originale" do
    original = comment(long("Fatto."), created_at: 5.days.ago)

    described_class.call(ticket: ticket)
    version = ticket.reports.first

    expect(version.author).to eq(original.author)
    expect(version.author_name).to eq(original.author.name)
    expect(version.created_at).to be_within(1.second).of(original.created_at)
    expect(version).to be_source_migrated
  end

  it "lascia stare i commenti già corti" do
    comment("Confermo.")

    expect { described_class.call(ticket: ticket) }.not_to change(Ticketing::Report, :count)
  end

  it "lascia stare le domande di chiarimento: hanno già casa nel loro record" do
    question = comment("#{long("DOMANDE:")}\n<!-- closeyourit-autopilot:waiting:v1 cycle=1 -->")

    described_class.call(ticket: ticket)

    expect(Ticketing::Report.where(source_comment_id: question.id)).to be_empty
  end

  it "è ripetibile: la seconda esecuzione non duplica niente" do
    comment(long("Fatto."))
    described_class.call(ticket: ticket)

    expect { described_class.call(ticket: ticket) }.not_to change(Ticketing::Report, :count)
  end

  it "prosegue la numerazione se il ticket ha già un resoconto scritto a mano" do
    create(:ticket_report, organization: organization, ticket: ticket, body: "Scritto a mano.")
    comment(long("Storico."))

    described_class.call(ticket: ticket)

    expect(ticket.reports.chronological.map(&:version)).to eq([ 1, 2 ])
    expect(ticket.reports.chronological.last.body).to start_with("Storico.")
  end

  it "non annuncia niente in discussione: la timeline storica non si falsifica" do
    comment(long("Fatto."))

    expect { described_class.call(ticket: ticket) }.not_to change(ticket.comments, :count)
  end
end
