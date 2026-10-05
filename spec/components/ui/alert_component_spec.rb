# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::AlertComponent, type: :component do
  it "rende la variante danger con icona e titolo" do
    render_inline(described_class.new(variant: :danger, title: "Errore")) { "operazione fallita" }
    expect(page).to have_css("div.bg-red-50 svg[data-icon='circle-alert']")
    expect(page).to have_css("span.font-semibold", text: "Errore")
    expect(page).to have_text("operazione fallita")
  end

  it "aggiunge controller e bottone quando dismissible" do
    render_inline(described_class.new(dismissible: true)) { "ciao" }
    expect(page).to have_css("div[data-controller='ui--alert']")
    expect(page).to have_css("button[data-action='ui--alert#dismiss']")
  end

  it "non è dismissible di default" do
    render_inline(described_class.new) { "ciao" }
    expect(page).not_to have_css("button[data-action='ui--alert#dismiss']")
  end

  it "solleva ArgumentError su variante sconosciuta" do
    expect { described_class.new(variant: :nope) }.to raise_error(ArgumentError)
  end

  it "varianti danger/warning → role alert + aria-live assertive (annunciato subito)" do
    render_inline(described_class.new(variant: :danger)) { "err" }
    expect(page.native.to_html).to include('role="alert"').and include('aria-live="assertive"')

    render_inline(described_class.new(variant: :warning)) { "attenzione" }
    expect(page.native.to_html).to include('role="alert"').and include('aria-live="assertive"')
  end

  it "varianti success/info → role status + aria-live polite (annunciato educatamente)" do
    render_inline(described_class.new(variant: :info)) { "ok" }
    expect(page.native.to_html).to include('role="status"').and include('aria-live="polite"')

    render_inline(described_class.new(variant: :success)) { "fatto" }
    expect(page.native.to_html).to include('role="status"').and include('aria-live="polite"')
  end

  it "icone decorative con aria-hidden e bottone dismiss con aria-label i18n" do
    render_inline(described_class.new(dismissible: true)) { "ciao" }
    html = page.native.to_html
    expect(html.scan('aria-hidden="true"').length).to eq(2) # icona variante + icona X
    expect(page).to have_css("button[aria-label='#{I18n.t('shared.actions.close')}']")
  end

  # A toast floats over the page: a see-through tint would let the page text show through it.
  it "gives every variant an opaque dark surface when it floats in the toast stack" do
    described_class::VARIANTS.each_key do |variant|
      render_inline(described_class.new(variant:)) { "ok" }
      box = page.find("[role]")[:class]
      expect(box).to match(/dark:in-\[#flash-container\]:bg-\w+-950/), "#{variant} toast is see-through in dark mode"
    end
  end
end
