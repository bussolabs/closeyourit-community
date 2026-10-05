# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::BadgeComponent, type: :component do
  it "rende la label" do
    render_inline(described_class.new(label: "In progress"))
    expect(page).to have_text("In progress")
  end

  it "applica le classi letterali del colore (indigo)" do
    render_inline(described_class.new(label: "In progress", color: :indigo))
    expect(page).to have_css("span.inline-flex.bg-indigo-50.text-indigo-600")
  end

  it "accetta il colore come stringa (dal DB)" do
    render_inline(described_class.new(label: "In review", color: "violet"))
    expect(page).to have_css("span.bg-violet-50.text-violet-600")
  end

  it "usa il tono neutro per gray" do
    render_inline(described_class.new(label: "Closed", color: :gray))
    expect(page).to have_css("span.bg-gray-100.text-gray-700")
  end

  it "fa fallback a gray per un colore fuori palette (niente raise)" do
    expect { render_inline(described_class.new(label: "Custom", color: :fuchsia)) }.not_to raise_error
    expect(page).to have_css("span.bg-gray-100.text-gray-700")
  end

  it "non mostra il pallino di default" do
    render_inline(described_class.new(label: "Open", color: :amber))
    expect(page).not_to have_css("span[class*='rounded-full']")
  end

  it "mostra il pallino colorato con dot: true" do
    render_inline(described_class.new(label: "Open", color: :amber, dot: true))
    expect(page).to have_css("span[class*='rounded-full'][class*='bg-amber-500']")
  end

  it "il pallino respira con pulse: true (motion-safe)" do
    render_inline(described_class.new(label: "In progress", color: :indigo, pulse: true))
    expect(page).to have_css("span[class*='rounded-full'][class*='motion-safe:animate-pulse']")
  end

  it "pulse: true implica il pallino anche senza dot esplicito" do
    render_inline(described_class.new(label: "In progress", color: :indigo, pulse: true))
    expect(page).to have_css("span[class*='bg-indigo-500']")
  end

  it "senza pulse il pallino non ha la classe di animazione" do
    render_inline(described_class.new(label: "Open", color: :amber, dot: true))
    expect(page).not_to have_css("span[class*='animate-pulse']")
  end

  it "renders the Lucide icon when given" do
    render_inline(described_class.new(label: "Owner", color: :indigo, icon: "crown"))
    expect(page).to have_css("svg[data-icon='crown']")
  end

  it "applica la size sm" do
    render_inline(described_class.new(label: "x", size: :sm))
    expect(page).to have_css("span.text-\\[10px\\]")
  end

  it "espone test_id come data-test" do
    render_inline(described_class.new(label: "x", test_id: "status-badge"))
    expect(page).to have_css("span[data-test='status-badge']")
  end

  it "preserva le classi passate dal caller" do
    render_inline(described_class.new(label: "x", color: :indigo, class: "ml-2"))
    expect(page).to have_css("span.ml-2.bg-indigo-50")
  end

  it "usa il contenuto del blocco se non c'è label" do
    render_inline(described_class.new(color: :gray)) { "via slot" }
    expect(page).to have_text("via slot")
  end

  it "solleva ArgumentError su size sconosciuta" do
    expect { described_class.new(label: "x", size: :huge) }.to raise_error(ArgumentError)
  end
end
