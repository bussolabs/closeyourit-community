# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::HistogramComponent, type: :component do
  let(:bars) do
    [
      { height: 100, color_class: "bg-indigo-500", time_label: "09:00–09:01", value_line: "3 occorrenze" },
      { height: 6, color_class: "bg-stone-200", time_label: "09:01–09:02", value_line: "nessuna occorrenza" }
    ]
  end
  let(:gridlines) { [ { value: 5, pct: 50.0 }, { value: 10, pct: 100.0 } ] }
  let(:xticks) { [ { label: "09:00", pct: 0.0 }, { label: "09:15", pct: 50.0 }, { label: "09:29", pct: 100.0 } ] }

  def render_default(**overrides)
    render_inline(described_class.new(
                    bars: bars, gridlines: gridlines, xticks: xticks,
                    buckets_test_id: "error-buckets", summary: "Riepilogo chart",
                    **overrides
                  ))
  end

  it "rende una barra per bucket con classe colore e altezza inline" do
    render_default
    expect(page).to have_css("span[data-monitoring--histogram-target='bar']", count: 2)
    expect(page).to have_css("span.bg-indigo-500[style*='height: 100%']")
    expect(page).to have_css("span.bg-stone-200[style*='height: 6%']")
  end

  it "espone i dati del tooltip come data-attribute sulla barra" do
    render_default
    bar = page.find("span[data-monitoring--histogram-target='bar']", match: :first)
    expect(bar["data-label"]).to eq("09:00–09:01")
    expect(bar["data-value"]).to eq("3 occorrenze")
  end

  it "arma l'hover del tooltip via data-action" do
    render_default
    bar = page.find("span[data-monitoring--histogram-target='bar']", match: :first)
    expect(bar["data-action"]).to include("mouseenter->monitoring--histogram#show")
    expect(bar["data-action"]).to include("mouseleave->monitoring--histogram#hide")
  end

  it "rende le gridline tratteggiate e le etichette valore del gutter Y" do
    render_default
    expect(page).to have_css("span.border-dashed.border-stone-200[style*='bottom: 100.0%']")
    expect(page).to have_text("5")
    expect(page).to have_text("10")
  end

  it "rende le etichette temporali dell'asse X" do
    render_default
    expect(page).to have_text("09:00")
    expect(page).to have_text("09:15")
    expect(page).to have_text("09:29")
  end

  it "ancora agli estremi le etichette X (0% a sinistra, 100% a destra) senza translate" do
    render_default
    expect(page).to have_css("span[style='left: 0']", text: "09:00")
    expect(page).to have_css("span[style='right: 0']", text: "09:29")
    expect(page).to have_css("span.-translate-x-1\\/2[style='left: 50.0%']", text: "09:15")
  end

  it "monta il controller Stimulus e il nodo tooltip nascosto (attributo [hidden], non .hidden)" do
    render_default
    expect(page).to have_css("div[data-controller='monitoring--histogram']")
    tooltip = page.find("[data-monitoring--histogram-target='tooltip']", visible: :all)
    expect(tooltip[:hidden]).to be_truthy
    expect(tooltip[:class]).not_to include("hidden")
    expect(page).to have_css("[data-monitoring--histogram-target='tooltipTime']", visible: :all)
    expect(page).to have_css("[data-monitoring--histogram-target='tooltipValue']", visible: :all)
  end

  it "usa il buckets_test_id sulla riga barre e sul summary sr-only" do
    render_default
    expect(page).to have_css("[data-test='error-buckets']")
    expect(page).to have_css("p.sr-only[data-test='error-buckets-summary']", text: "Riepilogo chart", visible: :all)
  end

  it "rende i bucket interattivi scorrevoli e abbastanza larghi da toccare su mobile" do
    interactive_bars = bars.map.with_index do |bar, index|
      bar.merge(href: "/errors?bucket=#{index}", aria_label: "Blocco #{index + 1}")
    end

    render_default(bars: interactive_bars)

    expect(page).to have_css("[data-controller='ui--scroll-hint'] [data-ui--scroll-hint-target='scroller'].overflow-x-auto")
    plot = page.find("[data-controller='monitoring--histogram']")
    # CYRA-663 — la larghezza minima segue il numero di barre invece di essere una costante
    # tarata su 56: con meno barre imponeva uno scorrimento che non serviva a niente.
    attesa = interactive_bars.size * Ui::HistogramComponent::MIN_BAR_WIDTH_PX
    expect(plot[:style]).to eq("--histogram-min-width: #{attesa}px")
    # Da tablet in su lo spazio basta: il grafico si stringe invece di scorrere.
    expect(plot[:class]).to include("min-w-(--histogram-min-width)", "md:min-w-0")
    expect(plot).to have_css("a[data-test='bucket-link']", count: 2)
    expect(page).to have_css("[data-ui--scroll-hint-target='horizontal'][hidden]",
                             text: I18n.t("shared.scroll_horizontal"), visible: :all)
  end

  it "senza gridline non rende alcuna riga tratteggiata (max < 2)" do
    render_default(gridlines: [])
    expect(page).not_to have_css("span.border-dashed")
  end

  # CYRA-472: i grafici di sistema dichiarano il fondo scala partendo da zero. L'etichetta di base si
  # appoggia al bordo inferiore: centrata (come le altre) sborderebbe per metà sotto il plot.
  it "ancora al bordo inferiore l'etichetta della gridline a 0, senza translate" do
    render_default(gridlines: [ { value: "0", pct: 0.0 }, { value: "50%", pct: 50.0 } ])

    expect(page).to have_css("span[style='bottom: 0']", text: "0")
    expect(page).not_to have_css("span.-translate-y-1\\/2[style='bottom: 0']")
    expect(page).to have_css("span.-translate-y-1\\/2[style='bottom: 50.0%']", text: "50%")
  end

  # L'etichetta del picco, centrata sulla sua riga, usciva sopra il grafico e copriva la riga del periodo.
  it "ancora al bordo superiore l'etichetta della gridline a 100, senza translate" do
    render_default(gridlines: [ { value: "50", pct: 50.0 }, { value: "373", pct: 100.0 } ])

    expect(page).to have_css("span[style='top: 0']", text: "373")
    expect(page).not_to have_css("span.-translate-y-1\\/2", text: "373")
  end

  it "accetta etichette Y già formattate con l'unità" do
    render_default(gridlines: [ { value: "16G", pct: 50.0 }, { value: "32G", pct: 100.0 } ])

    expect(page).to have_text("16G")
    expect(page).to have_text("32G")
  end

  # «95,4 MB» andava a capo in un gutter fisso da 2rem e si sovrapponeva alla riga vicina.
  it "tiene su una riga le etichette Y e allarga il gutter all'etichetta più lunga" do
    render_default(gridlines: [ { value: "0", pct: 0.0 }, { value: "95,4 MB", pct: 100.0 } ])

    expect(page).to have_css("span.whitespace-nowrap[style='top: 0']", text: "95,4 MB")
    expect(page).to have_css("div[aria-hidden='true'][style='width: max(2rem, 7ch)']", count: 2)
  end

  # CYRA-457: un blocco senza campioni (`unsampled: true`) si distingue da una barra a valore zero.
  # Reso come fascia tratteggiata a piena altezza (bg-hatch + self-stretch), non come barra height%.
  context "blocco non misurato (unsampled)" do
    let(:hatch_bars) do
      [
        { height: 20, color_class: "bg-emerald-400", time_label: "09:00–09:01", value_line: "20%", unsampled: false },
        { height: 6, color_class: "bg-stone-200/80", time_label: "09:01–09:02", value_line: "nessun dato", unsampled: true }
      ]
    end

    def render_hatch
      render_inline(described_class.new(bars: hatch_bars, gridlines: gridlines, xticks: xticks,
                                        buckets_test_id: "server-cpu-buckets", summary: "Riepilogo chart"))
    end

    it "rende il blocco non misurato come fascia tratteggiata a piena altezza (niente height inline)" do
      render_hatch
      hatch = page.find("span.bg-hatch")
      expect(hatch[:class]).to include("self-stretch")
      expect(hatch[:style].to_s).not_to include("height")
    end

    it "il blocco misurato resta una barra colorata con height inline" do
      render_hatch
      expect(page).to have_css("span.bg-emerald-400[style*='height: 20%']")
      expect(page).not_to have_css("span.bg-emerald-400.bg-hatch")
    end

    it "porta comunque il tooltip (finestra + 'nessun dato') sul blocco tratteggiato" do
      render_hatch
      hatch = page.find("span.bg-hatch")
      expect(hatch["data-label"]).to eq("09:01–09:02")
      expect(hatch["data-value"]).to eq("nessun dato")
      expect(hatch["data-action"]).to include("mouseenter->monitoring--histogram#show")
    end
  end

  # CYRA-570: un periodo in cui non è stato misurato niente non si disegna. Una fila di barrette
  # tutte della stessa altezza minima si legge come «pochissimo traffico» invece che «nessun dato»,
  # e occupa un quarto di schermata per non dire nulla. Qui il grafico lo dichiara a parole, a
  # schermo (non solo per i lettori di schermo) e in una riga sola.
  context "periodo senza dati (CYRA-570)" do
    let(:empty_bars) do
      [
        { height: 6, color_class: "bg-stone-200", time_label: "09:00–09:01", value_line: "nessuna occorrenza", empty: true },
        { height: 6, color_class: "bg-stone-200", time_label: "09:01–09:02", value_line: "nessuna occorrenza", empty: true }
      ]
    end

    def render_empty(bars_override = empty_bars, **overrides)
      render_inline(described_class.new(bars: bars_override, gridlines: [], xticks: xticks,
                                        buckets_test_id: "error-buckets", summary: "Riepilogo chart", **overrides))
    end

    it "dichiara che non ci sono dati invece di disegnare le barre" do
      render_empty

      expect(page).to have_css("[data-test='error-buckets-empty']", text: I18n.t("shared.histogram.empty"))
      expect(page).not_to have_css("[data-test='error-buckets']")
      expect(page).not_to have_css("[data-monitoring--histogram-target='bar']", visible: :all)
    end

    it "la frase si legge a schermo, non solo con un lettore di schermo" do
      render_empty

      expect(page).not_to have_css("p.sr-only", visible: :all)
      expect(page.find("[data-test='error-buckets-empty']")[:class]).not_to include("sr-only")
    end

    it "non tiene in piedi l'altezza del plot per non dire niente" do
      render_empty

      expect(page).not_to have_css(".h-28")
    end

    it "usa l'etichetta di dominio quando il chiamante la passa" do
      render_empty(empty_bars, empty_label: "Nessun messaggio in questo periodo.")

      expect(page).to have_text("Nessun messaggio in questo periodo.")
      expect(page).not_to have_text(I18n.t("shared.histogram.empty"))
    end

    it "lo dichiara anche quando non c'è nemmeno un blocco da disegnare" do
      render_empty([])

      expect(page).to have_css("[data-test='error-buckets-empty']")
    end

    it "blocchi tutti non misurati: nessuna fascia tratteggiata larga quanto il grafico" do
      render_empty([ { height: 6, time_label: "09:00–09:01", value_line: "nessun dato", unsampled: true } ])

      expect(page).not_to have_css("span.bg-hatch")
      expect(page).to have_css("[data-test='error-buckets-empty']")
    end

    it "basta un blocco con dati e il grafico si disegna come sempre" do
      render_empty(empty_bars + [ { height: 100, color_class: "bg-indigo-500", time_label: "09:02–09:03", value_line: "3 occorrenze" } ])

      expect(page).to have_css("[data-test='error-buckets']")
      expect(page).to have_css("span.bg-indigo-500[style*='height: 100%']")
      expect(page).not_to have_css("[data-test='error-buckets-empty']")
    end
  end

  # CYRA-46: barre cliccabili per il drill-down. Un blocco con `href` diventa un link (<a>),
  # accessibile (aria-label, container non aria-hidden); un blocco senza href resta uno <span>.
  context "barre cliccabili (drill-down istogramma)" do
    let(:link_bars) do
      [
        { height: 100, color_class: "bg-indigo-500", time_label: "09:00–09:30", value_line: "3 occorrenze",
          href: "/e?from=1&to=2", active: true, aria_label: "09:00–09:30 · 3 occorrenze" },
        { height: 6, color_class: "bg-stone-200", time_label: "09:30–10:00", value_line: "nessuna occorrenza",
          href: nil, active: false, aria_label: "09:30–10:00 · nessuna occorrenza" }
      ]
    end

    def render_links
      render_inline(described_class.new(bars: link_bars, gridlines: gridlines, xticks: xticks,
                                        buckets_test_id: "error-buckets", summary: "Riepilogo chart"))
    end

    it "rende un <a> cliccabile per il blocco con href (from/to nell'URL)" do
      render_links
      expect(page).to have_css("a[data-test='bucket-link'][href='/e?from=1&to=2']")
    end

    it "il blocco senza href resta uno <span> non cliccabile" do
      render_links
      expect(page).to have_css("span[data-monitoring--histogram-target='bar'][data-value='nessuna occorrenza']")
      expect(page).not_to have_css("a[href='/e?from=1&to=2'] + a")
    end

    it "evidenzia col ring il blocco attivo" do
      render_links
      expect(page).to have_css("a[data-test='bucket-link'].ring-2.ring-indigo-500")
    end

    it "espone aria-label sul link per l'accessibilità" do
      render_links
      expect(page.find("a[data-test='bucket-link']")["aria-label"]).to eq("09:00–09:30 · 3 occorrenze")
    end

    it "quando interattivo il container barre NON è aria-hidden (i link devono essere raggiungibili)" do
      render_links
      expect(page).not_to have_css("[data-test='error-buckets'][aria-hidden]")
    end

    it "porta il tooltip hover anche sul link (data-label/data-value/data-action)" do
      render_links
      link = page.find("a[data-test='bucket-link']")
      expect(link["data-label"]).to eq("09:00–09:30")
      expect(link["data-value"]).to eq("3 occorrenze")
      expect(link["data-action"]).to include("mouseenter->monitoring--histogram#show")
    end
  end
  it "positions opt-in signed bars from a zero baseline without changing legacy bars" do
    render_default(bars: [
      { height: 50, bottom: 0, color_class: "bg-indigo-500", value_line: "-9" },
      { height: 50, bottom: 50, color_class: "bg-indigo-500", value_line: "9" },
      { height: 0, bottom: 50, color_class: "bg-indigo-500", value_line: "0" },
      { unsampled: true, value_line: "Unknown" }
    ], gridlines: [ { value: "0", pct: 50, baseline: true } ])
    expect(page).to have_css('[data-value="-9"][style*="bottom: 0%"]')
    expect(page).to have_css('[data-value="9"][style*="bottom: 50%"]')
    expect(page).to have_css('[data-value="0"][style*="height: max(1px, 0%)"]')
    expect(page).to have_css('[data-value="Unknown"].bg-hatch')
    expect(page).to have_css('[data-zero-baseline][style="bottom: 50%"]')
  end
end
