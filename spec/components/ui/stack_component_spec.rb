# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::StackComponent, type: :component do
  it "impila in verticale con la distanza chiesta" do
    render_inline(described_class.new(gap: 6)) { "corpo" }

    expect(page).to have_css("div.space-y-6", text: "corpo")
  end

  it "mette in riga, allinea e distanzia" do
    render_inline(described_class.new(direction: :row, gap: 2, align: :center)) { "corpo" }

    expect(page).to have_css("div.flex.items-center.gap-2", text: "corpo")
  end

  it "manda a capo la riga quando glielo si chiede" do
    render_inline(described_class.new(direction: :row, gap: 2, wrap: true)) { "corpo" }

    expect(page).to have_css("div.flex.flex-wrap.gap-2")
  end

  it "distribuisce agli estremi" do
    render_inline(described_class.new(direction: :row, gap: 3, align: :center, justify: :between)) { "corpo" }

    expect(page).to have_css("div.flex.items-center.justify-between.gap-3")
  end

  it "unisce le classi del chiamante senza perdere le proprie" do
    render_inline(described_class.new(gap: 4, class: "mt-2", test_id: "pila")) { "corpo" }

    expect(page).to have_css("div.space-y-4.mt-2[data-test='pila']")
  end

  # Le classi sono LETTERALI (lo scanner Tailwind purga le interpolate): una distanza fuori mappa
  # scriverebbe una classe che nel foglio di stile non esiste, e la pagina uscirebbe senza spazi.
  it "rifiuta una distanza che non esiste nella mappa" do
    expect { render_inline(described_class.new(gap: 99)) }.to raise_error(ArgumentError, /gap/)
  end

  it "rifiuta una direzione sconosciuta" do
    expect { render_inline(described_class.new(direction: :diagonale)) }.to raise_error(ArgumentError, /direction/)
  end
end
