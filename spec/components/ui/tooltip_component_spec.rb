# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::TooltipComponent, type: :component do
  it "rende il pallino con l'icona info di default" do
    render_inline(described_class.new(text: "Aiuto"))
    expect(page).to have_css("button svg[data-icon='info']", visible: :all)
  end

  it "rende l'icona personalizzata quando passata" do
    render_inline(described_class.new(text: "Aiuto", icon: "circle-question-mark"))
    expect(page).to have_css("button svg[data-icon='circle-question-mark']", visible: :all)
  end

  it "il pallino è un button focusabile da tastiera" do
    render_inline(described_class.new(text: "Aiuto"))
    expect(page).to have_css("button[type='button']", visible: :all)
  end

  it "applica il tono info di default (cerchio azzurro, i bianca)" do
    render_inline(described_class.new(text: "Aiuto"))
    expect(page).to have_css("button.bg-sky-500.text-white", visible: :all)
    expect(page).not_to have_css("button.bg-zinc-800", visible: :all)
  end

  it "applica il tono muted (solo icona grigia, nessun pallino pieno)" do
    render_inline(described_class.new(text: "Aiuto", tone: :muted))
    expect(page).to have_css("button.text-gray-500", visible: :all)
    expect(page).not_to have_css("button.bg-sky-500", visible: :all)
  end

  it "applica il tono tip (cerchio verde)" do
    render_inline(described_class.new(text: "Consiglio", tone: :tip))
    expect(page).to have_css("button.bg-emerald-100.text-emerald-700", visible: :all)
    expect(page).not_to have_css("button.bg-amber-100", visible: :all)
    expect(page).not_to have_css("button.bg-sky-500", visible: :all)
  end

  it "rende la lampadina di default con il tono tip" do
    render_inline(described_class.new(text: "Consiglio", tone: :tip))
    expect(page).to have_css("button svg[data-icon='lightbulb']", visible: :all)
    expect(page).not_to have_css("button svg[data-icon='info']", visible: :all)
  end

  it "l'icona esplicita vince anche con il tono tip" do
    render_inline(described_class.new(text: "Consiglio", tone: :tip, icon: "star"))
    expect(page).to have_css("button svg[data-icon='star']", visible: :all)
    expect(page).not_to have_css("button svg[data-icon='lightbulb']", visible: :all)
  end

  it "renderizza il testo dentro il pannello role=tooltip" do
    render_inline(described_class.new(text: "S.M.A.R.T. è lo stato di salute dei dischi."))
    expect(page).to have_css("span[role='tooltip']", text: "S.M.A.R.T. è lo stato di salute dei dischi.", visible: :all)
  end

  it "il pannello è nascosto di default via attributo hidden" do
    render_inline(described_class.new(text: "Aiuto"))
    expect(page).to have_css("span[role='tooltip'][hidden]", visible: :all)
  end

  it "mostra il titolo in grassetto quando presente" do
    render_inline(described_class.new(title: "Fingerprint", text: "Impronta dell'errore."))
    expect(page).to have_css("span.font-semibold", text: "Fingerprint", visible: :all)
  end

  it "non rende alcun nodo titolo quando il titolo è assente" do
    render_inline(described_class.new(text: "Solo testo."))
    expect(page).not_to have_css("span.font-semibold", visible: :all)
  end

  it "collega il button al pannello via aria-describedby" do
    render_inline(described_class.new(text: "Aiuto"))
    panel_id = page.find("span[role='tooltip']", visible: :all)[:id]
    expect(panel_id).to be_present
    expect(page).to have_css("button[aria-describedby='#{panel_id}']", visible: :all)
  end

  it "aggancia il controller Stimulus ui--tooltip e passa il placement" do
    render_inline(described_class.new(text: "Aiuto", placement: :bottom))
    expect(page).to have_css("span[data-controller='ui--tooltip'][data-ui--tooltip-placement-value='bottom']", visible: :all)
  end

  it "registra le action hover/focus/esc sul trigger" do
    render_inline(described_class.new(text: "Aiuto"))
    action = page.find("button", visible: :all)["data-action"]
    expect(action).to include("mouseenter->ui--tooltip#show")
    expect(action).to include("focus->ui--tooltip#show")
    expect(action).to include("mouseleave->ui--tooltip#hide")
    expect(action).to include("keydown.esc->ui--tooltip#hideOnEsc")
  end

  it "usa il placement top come fallback statico di default" do
    render_inline(described_class.new(text: "Aiuto"))
    expect(page).to have_css("span[role='tooltip'].bottom-full", visible: :all)
  end

  it "usa il placement bottom come fallback statico quando richiesto" do
    render_inline(described_class.new(text: "Aiuto", placement: :bottom))
    expect(page).to have_css("span[role='tooltip'].top-full", visible: :all)
  end

  it "espone test_id come data-test sul wrapper" do
    render_inline(described_class.new(text: "Aiuto", test_id: "help-smart"))
    expect(page).to have_css("span[data-controller='ui--tooltip'][data-test='help-smart']", visible: :all)
  end

  it "preserva le classi passate dal caller sul wrapper" do
    render_inline(described_class.new(text: "Aiuto", class: "ml-1"))
    expect(page).to have_css("span.ml-1[data-controller='ui--tooltip']", visible: :all)
  end

  it "solleva ArgumentError su tono sconosciuto" do
    expect { described_class.new(text: "x", tone: :neon) }.to raise_error(ArgumentError)
  end

  it "solleva ArgumentError su placement sconosciuto" do
    expect { described_class.new(text: "x", placement: :left) }.to raise_error(ArgumentError)
  end
end
