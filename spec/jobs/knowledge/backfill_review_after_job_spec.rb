# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::BackfillReviewAfterJob, type: :job do
  def vecchia(kind:, updated: 3.years.ago)
    create(:knowledge_page, kind: kind).tap { |page| page.update_columns(updated_at: updated) }
  end

  it "dà una data alle decisioni e alle guide che non ce l'hanno" do
    decisione = vecchia(kind: :decision)
    guida = vecchia(kind: :guide)

    described_class.perform_now

    expect(decisione.reload.review_after).to be_present
    expect(guida.reload.review_after).to be_present
  end

  it "lascia le note senza scadenza" do
    nota = vecchia(kind: :note)

    described_class.perform_now

    expect(nota.reload.review_after).to be_nil
  end

  it "non tocca una pagina che ha già la sua data" do
    page = vecchia(kind: :decision)
    gia_fissata = 10.days.from_now.change(usec: 0)
    page.update_columns(review_after: gia_fissata)

    described_class.perform_now

    expect(page.reload.review_after).to eq(gia_fissata)
  end

  it "non tocca le proposte in revisione né le scartate: il conto parte dall'accettazione" do
    proposta = create(:knowledge_page, :in_review, :decision)
    scartata = create(:knowledge_page, :rejected, :decision)

    described_class.perform_now

    expect(proposta.reload.review_after).to be_nil
    expect(scartata.reload.review_after).to be_nil
  end

  # Il rischio scritto nel ticket: applicare i default retroattivamente riempirebbe la coda di colpo.
  it "spalma le pagine già scadute su giorni diversi invece di farle scadere tutte insieme" do
    pagine = Array.new(5) { vecchia(kind: :decision) }

    described_class.perform_now

    giorni = pagine.map { |page| page.reload.review_after.to_date }
    expect(giorni.uniq.size).to eq(5)
    expect(giorni).to all(be >= Date.current)
  end

  # L'ordine conta: la coda deve aprirsi con le pagine più stantie, non con quelle che il database
  # restituisce per prime. `find_each` scarta l'ordinamento chiesto e impone quello per chiave.
  it "manda in coda per prima la pagina più stantia" do
    recente = vecchia(kind: :decision, updated: 2.years.ago)
    stantia = vecchia(kind: :decision, updated: 6.years.ago)

    described_class.perform_now

    expect(stantia.reload.review_after).to be < recente.reload.review_after
  end

  it "tiene la data naturale quando cade comunque nel futuro" do
    recente = create(:knowledge_page, :guide)
    recente.update_columns(updated_at: 2.days.ago)

    described_class.perform_now

    expect(recente.reload.review_after).to be_within(1.minute).of(recente.updated_at + 365.days)
  end

  it "è ripetibile: un secondo giro non sposta niente" do
    page = vecchia(kind: :decision)

    described_class.perform_now
    prima = page.reload.review_after
    described_class.perform_now

    expect(page.reload.review_after).to eq(prima)
  end
end
