# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::MeterComponent, type: :component do
  it "mostra etichetta e valore" do
    render_inline(described_class.new(label: "GB10", value_text: "45°", pct: 45))

    expect(page).to have_text("GB10")
    expect(page).to have_text("45°")
  end

  it "un'etichetta troppo lunga per la colonna resta leggibile intera al passaggio del mouse" do
    render_inline(described_class.new(label: "Attesa in scrittura", value_text: "0.46 ms", pct: 2))

    expect(page).to have_css("span[title='Attesa in scrittura']", text: "Attesa in scrittura")
  end

  it "riempie la barra in proporzione al valore" do
    render_inline(described_class.new(label: "core 3", value_text: "50%", pct: 50, test_id: "core-3"))

    expect(page.find("[data-test='core-3-fill']")[:style]).to include("width: 50%")
  end

  it "non lascia sbordare la barra oltre il fondo scala" do
    render_inline(described_class.new(label: "carico", value_text: "180%", pct: 180, test_id: "carico"))

    expect(page.find("[data-test='carico-fill']")[:style]).to include("width: 100%")
  end

  it "non disegna una barra negativa" do
    render_inline(described_class.new(label: "delta", value_text: "—", pct: -5, test_id: "delta"))

    expect(page.find("[data-test='delta-fill']")[:style]).to include("width: 0%")
  end

  it "ripiega sul colore neutro quando il colore chiesto non esiste" do
    render_inline(described_class.new(label: "x", value_text: "1", pct: 10, color: :fucsia, test_id: "x"))

    expect(page.find("[data-test='x-fill']")[:class]).to include("bg-zinc-400")
  end
end
