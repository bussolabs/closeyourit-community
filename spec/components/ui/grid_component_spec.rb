# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::GridComponent, type: :component do
  it "rende una griglia a colonne fisse" do
    render_inline(described_class.new(cols: 2, gap_y: 3, gap_x: 4)) { "corpo" }

    expect(page).to have_css("div.grid.grid-cols-2.gap-y-3.gap-x-4", text: "corpo")
  end

  it "cresce di colonne alle larghezze dichiarate, nell'ordine dei breakpoint" do
    render_inline(described_class.new(cols: 1, md: 2, lg: 3, gap: 6)) { "corpo" }

    expect(page).to have_css("div.grid.grid-cols-1.md\\:grid-cols-2.lg\\:grid-cols-3.gap-6")
    expect(page.native.to_html).to include('class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6"')
  end

  it "unisce le classi del chiamante e marca il blocco per le prove" do
    render_inline(described_class.new(cols: 1, sm: 2, gap: 4, class: "mt-3", test_id: "griglia")) { "corpo" }

    expect(page).to have_css("div.grid.mt-3[data-test='griglia']")
  end

  it "rifiuta un numero di colonne fuori mappa" do
    expect { render_inline(described_class.new(cols: 13)) }.to raise_error(ArgumentError, /cols/)
  end

  it "rifiuta un numero di colonne fuori mappa anche su un breakpoint" do
    expect { render_inline(described_class.new(cols: 1, lg: 13)) }.to raise_error(ArgumentError, /lg/)
  end
end
