# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::MetricTileComponent, type: :component do
  it "rende la label e il valore" do
    render_inline(described_class.new(label: "Unresolved errors", value: 7))
    expect(page).to have_text("Unresolved errors")
    expect(page).to have_text("7")
  end

  it "renders the Lucide icon when given" do
    render_inline(described_class.new(label: "Errori", value: 0, icon: "bug"))
    expect(page).to have_css("svg[data-icon='bug']")
  end

  it "non rende alcuna icona quando assente" do
    render_inline(described_class.new(label: "Errori", value: 0))
    expect(page).not_to have_css("svg[data-icon]")
  end

  it "applica il colore letterale del valore (red)" do
    render_inline(described_class.new(label: "Errori", value: 3, value_color: :red))
    expect(page).to have_css("p.text-red-600", text: "3")
  end

  it "usa il tono neutro (zinc-900) di default" do
    render_inline(described_class.new(label: "Nuovi", value: 0))
    expect(page).to have_css("p.text-zinc-900", text: "0")
  end

  it "accetta il value_color come stringa" do
    render_inline(described_class.new(label: "Perf", value: 2, value_color: "violet"))
    expect(page).to have_css("p.text-violet-600", text: "2")
  end

  it "fa fallback a neutral per un value_color fuori mappa (niente raise)" do
    expect { render_inline(described_class.new(label: "x", value: 1, value_color: :fuchsia)) }.not_to raise_error
    expect(page).to have_css("p.text-zinc-900", text: "1")
  end

  it "fa fallback a neutral quando value_color è nil (niente raise)" do
    expect { render_inline(described_class.new(label: "x", value: 1, value_color: nil)) }.not_to raise_error
    expect(page).to have_css("p.text-zinc-900", text: "1")
  end

  it "fa fallback a neutral quando delta_color è nil (niente raise)" do
    expect { render_inline(described_class.new(label: "x", value: 1, delta: "+1", delta_color: nil)) }.not_to raise_error
    expect(page).to have_css("p.text-zinc-900", text: "+1")
  end

  # --- variante NON cliccabile (div statico) ---

  it "senza href rende un contenitore <div> non cliccabile" do
    render_inline(described_class.new(label: "Incidents", value: 0))
    expect(page).to have_css("div.rounded-\\[10px\\]")
    expect(page).not_to have_css("a")
  end

  it "rende il tooltip come attributo title nativo sul contenitore statico" do
    render_inline(described_class.new(label: "Silent", value: 1, tooltip: "Sembrano sani solo per assenza di dati"))
    expect(page).to have_css("div[title='Sembrano sani solo per assenza di dati']")
  end

  # --- variante cliccabile (link) ---

  it "con href rende un link <a> verso l'href" do
    render_inline(described_class.new(label: "Errori", value: 3, href: "/errors"))
    expect(page).to have_css("a[href='/errors']")
  end

  it "il link espone hover e focus-ring indigo per l'accessibilità da tastiera" do
    render_inline(described_class.new(label: "Errori", value: 3, href: "/errors"))
    html = page.native.to_html
    expect(html).to include("hover:bg-stone-50")
    expect(html).to include("focus-visible:ring-indigo-500/40")
  end

  it "espone aria-label sul link quando passato" do
    render_inline(described_class.new(label: "Errori", value: 3, href: "/errors", aria_label: "Vedi gli errori non risolti"))
    expect(page).to have_css("a[aria-label='Vedi gli errori non risolti']")
  end

  # --- data-test (wrapper + valore) ---

  it "espone value_test_id come data-test sul valore" do
    render_inline(described_class.new(label: "Errori", value: 3, value_test_id: "home-stat-errors"))
    expect(page).to have_css("p[data-test='home-stat-errors']", text: "3")
  end

  it "espone test_id come data-test sul wrapper link" do
    render_inline(described_class.new(label: "Errori", value: 3, href: "/errors", test_id: "home-kpi-errors"))
    expect(page).to have_css("a[data-test='home-kpi-errors']")
  end

  it "espone test_id come data-test sul wrapper statico" do
    render_inline(described_class.new(label: "Incidents", value: 0, test_id: "home-kpi-incidents"))
    expect(page).to have_css("div[data-test='home-kpi-incidents']")
  end

  # --- caption / delta ---

  it "rende la caption sotto il valore quando passata" do
    render_inline(described_class.new(label: "Errori", value: 3, caption: "ultime 24h"))
    expect(page).to have_css("p", text: "ultime 24h")
  end

  it "non rende alcuna caption quando assente" do
    render_inline(described_class.new(label: "Errori", value: 3))
    expect(page).to have_css("p", count: 1) # solo il valore
  end

  it "rende il delta col proprio colore quando passato" do
    render_inline(described_class.new(label: "Errori", value: 3, delta: "+12%", delta_color: :emerald))
    expect(page).to have_css("p.text-emerald-600", text: "+12%")
  end

  it "il valore resta isolato: caption e delta non ne inquinano il testo (boundary)" do
    render_inline(described_class.new(
                    label: "Errori", value: 42, value_test_id: "m-value",
                    caption: "ultime 24h", delta: "+12%", delta_color: :emerald))
    expect(page.find("[data-test='m-value']").text.strip).to eq("42")
  end

  # --- merge non distruttivo ---

  it "preserva le classi passate dal caller sul wrapper" do
    render_inline(described_class.new(label: "Errori", value: 3, class: "col-span-2"))
    expect(page).to have_css("div.col-span-2.rounded-\\[10px\\]")
  end
end
