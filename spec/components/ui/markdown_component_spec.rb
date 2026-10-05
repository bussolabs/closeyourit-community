# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::MarkdownComponent, type: :component do
  it "rende il markdown a blocchi dentro un contenitore prose" do
    render_inline(described_class.new(text: "## Titolo\n\n- primo\n- secondo"))

    expect(page).to have_css("div.prose h2", text: "Titolo")
    expect(page).to have_css("div.prose ul li", count: 2)
  end

  # prose-stone paints <code> stone-900: on the dark zinc-800 chip it was unreadable.
  it "gives inline code a light text color in the dark theme" do
    render_inline(described_class.new(text: "use `src/price.js`\n\n- item"))

    expect(page).to have_css("div.prose[class~='dark:prose-code:text-zinc-100']")
  end

  it "uses only well-formed dark variants in the inline variant" do
    render_inline(described_class.new(text: "a `code` and [link](https://example.com)", inline: true))

    classes = page.find("span")[:class].split
    expect(classes.grep(/\Adark:_/)).to be_empty
    expect(classes).to include("dark:[&_a]:text-indigo-400")
  end

  it "rende la variante inline senza il paragrafo, dentro uno span" do
    render_inline(described_class.new(text: "il **piano** è pronto", inline: true))

    expect(page).to have_css("span strong", text: "piano")
    expect(page).not_to have_css("span p")
  end

  # Uno <span> che contiene un <ul> è HTML invalido: dentro un <p> il parser chiude il paragrafo,
  # riapre lo span dopo e il contenuto esce dal contenitore, classi comprese.
  it "passa a div quando il testo inline ha più di un blocco" do
    render_inline(described_class.new(text: "prima riga\n\n- elenco", inline: true))

    expect(page).to have_css("div ul li", text: "elenco")
    expect(page).not_to have_css("span")
  end

  # CYRA-992 — Coworkers answers list bare URLs as sources: the full address wraps over whole lines.
  it "shortens bare links to their site name when short_links is on" do
    render_inline(described_class.new(text: "Source: https://www.frontemarerimini.it/events/october", short_links: true))

    link = page.find("a[href='https://www.frontemarerimini.it/events/october']")
    expect(link).to have_text("frontemarerimini.it ↗")
    expect(link[:title]).to eq("https://www.frontemarerimini.it/events/october")
  end

  it "keeps written link text and bare links when short_links is off" do
    render_inline(described_class.new(text: "[the club](https://classic.example/) and https://www.example.com/a", short_links: true))
    expect(page).to have_css("a", text: "the club")

    render_inline(described_class.new(text: "https://www.example.com/a"))
    expect(page).to have_css("a", text: "https://www.example.com/a")
  end

  it "porta il data-test sul contenitore" do
    render_inline(described_class.new(text: "ciao", test_id: "automation-plan-analysis"))

    expect(page).to have_css('div[data-test="automation-plan-analysis"]', text: "ciao")
  end

  it "unisce le classi del caller senza perdere quelle del componente" do
    render_inline(described_class.new(text: "ciao", class: "px-4 py-3.5"))

    expect(page).to have_css("div.prose.px-4.py-3\\.5")
  end

  # Due `max-w-*` sullo stesso elemento non si sommano: vincerebbe quella scritta più avanti nel CSS
  # generato, cioè `max-w-none`, e la misura leggibile scelta dalla pagina (Knowledge, analisi
  # tecnica) sparirebbe senza che nessuno se ne accorga.
  it "cede la misura al caller quando è lui a portarne una" do
    render_inline(described_class.new(text: "ciao", class: "max-w-[70ch]"))

    expect(page).to have_css("div.max-w-\\[70ch\\]")
    expect(page).not_to have_css("div.max-w-none")
  end

  it "tiene max-w-none quando il caller non decide la misura" do
    render_inline(described_class.new(text: "ciao"))

    expect(page).to have_css("div.max-w-none")
  end

  it "escapa l'HTML grezzo scritto da chi ha compilato il testo" do
    render_inline(described_class.new(text: "<script>alert(1)</script>"))

    expect(page).not_to have_css("script", visible: :all)
    expect(page).to have_text("<script>alert(1)</script>")
  end

  it "non lascia partire le immagini remote (default sicuro)" do
    render_inline(described_class.new(text: "![pixel](https://tracker.example/p.png)"))

    expect(page).not_to have_css("img")
    expect(page).to have_text("tracker.example/p.png")
  end

  it "mostra le immagini remote solo se chi lo usa lo chiede" do
    render_inline(described_class.new(text: "![pixel](https://cdn.example/p.png)", remote_images: true))

    expect(page).to have_css('img[src="https://cdn.example/p.png"]')
  end

  it "tiene gli a capo singoli del testo senza formattazione" do
    render_inline(described_class.new(text: "prima riga\nseconda riga"))

    expect(page).to have_css("br")
  end

  it "rende il contenitore anche col testo vuoto (i data-test restano agganciabili)" do
    render_inline(described_class.new(text: nil, test_id: "ticket-description"))

    expect(page).to have_css('div[data-test="ticket-description"]')
  end
end
