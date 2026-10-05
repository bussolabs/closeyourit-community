# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::DescriptionListComponent, type: :component do
  it "rende le coppie etichetta/valore su due colonne" do
    render_inline(described_class.new(test_id: "dettagli")) do |list|
      list.with_item(label: "Prima vista", value: "01/09 10:00")
      list.with_item(label: "Ultima vista", value: "adesso")
    end

    expect(page).to have_css("div.grid.grid-cols-2.gap-y-3.gap-x-4[data-test='dettagli']")
    expect(page).to have_css("p.font-mono.uppercase", text: "Prima vista")
    expect(page).to have_text("01/09 10:00")
  end

  # La grafia dell'etichetta è quella che le pagine hanno già scritta a mano quasi cento volte.
  it "scrive etichetta e valore con la grafia delle pagine" do
    render_inline(described_class.new) { |list| list.with_item(label: "Impronta", value: "abc123") }

    expect(page.native.to_html).to include(
      '<p class="font-mono uppercase text-[9.5px] tracking-[1.2px] text-gray-500 dark:text-zinc-400">Impronta</p>'
    )
    expect(page.native.to_html).to include('<p class="mt-1 font-mono text-[12px] text-zinc-900 dark:text-zinc-100">abc123</p>')
  end

  it "fa occupare a una voce l'intera larghezza" do
    render_inline(described_class.new) { |list| list.with_item(label: "Progetto", value: "CYRA", span: 2) }

    expect(page).to have_css("div.col-span-2")
  end

  it "marca la singola voce per le prove" do
    render_inline(described_class.new) { |list| list.with_item(label: "Ticket", value: "—", test_id: "detail-ticket") }

    expect(page).to have_css("div[data-test='detail-ticket']")
  end

  it "accetta un valore composto al posto della stringa" do
    render_inline(described_class.new) do |list|
      list.with_item(label: "Progetto") { "<a href='/x'>CloseYourIt</a>".html_safe }
    end

    expect(page).to have_css("a[href='/x']", text: "CloseYourIt")
  end

  # L'aiuto accanto all'etichetta esiste già nelle pagine («impronta», «punto del codice»): senza
  # slot ognuno lo riscriverebbe con un allineamento suo.
  it "affianca all'etichetta il suo aiuto" do
    render_inline(described_class.new) do |list|
      list.with_item(label: "Impronta", value: "abc", hint: "Come si calcola", hint_test_id: "help-fingerprint")
    end

    expect(page).to have_css("p.font-mono.uppercase.flex.items-center.gap-1", text: "Impronta")
    expect(page).to have_css("[data-test='help-fingerprint']")
  end

  it "cambia la grafia del valore quando non è monospazio" do
    render_inline(described_class.new) do |list|
      list.with_item(label: "Nota", value: "testo", value_class: "mt-1 text-[12.5px] text-gray-500")
    end

    expect(page.native.to_html).to include('<p class="mt-1 text-[12.5px] text-gray-500">testo</p>')
  end

  it "separa una voce dalle successive quando glielo si chiede" do
    render_inline(described_class.new) do |list|
      list.with_item(label: "Ticket", value: "—", span: 2, class: "pb-3 border-b border-stone-100")
    end

    expect(page).to have_css("div.col-span-2.pb-3.border-b.border-stone-100")
  end

  it "rifiuta un numero di colonne fuori mappa" do
    expect { render_inline(described_class.new(columns: 7)) }.to raise_error(ArgumentError, /columns/)
  end
end
