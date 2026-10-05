# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::RowActionsFormComponent, type: :component do
  it "rende un solo modulo, nascosto, con l'id che le azioni di riga puntano" do
    render_inline(described_class.new)

    expect(page).to have_css("form#row-actions.hidden[method='post']", visible: :all)
    expect(page.native.css("form").size).to eq(1)
  end

  it "non fissa un'azione: la sceglie il bottone di riga col suo formaction" do
    render_inline(described_class.new)

    expect(page).to have_no_css("form[action]", visible: :all)
  end

  it "accetta un id diverso quando in pagina servono due elenchi" do
    render_inline(described_class.new(id: "vault-actions", test_id: "vault-actions-form"))

    expect(page).to have_css("form#vault-actions[data-test='vault-actions-form']", visible: :all)
  end

  # Il token deve valere per QUALUNQUE indirizzo: quello legato a una singola azione (per-form)
  # verrebbe rifiutato appena il bottone punta altrove con formaction, e le decisioni fallirebbero
  # tutte in produzione — dove la protezione è accesa e nei test no.
  describe "con la protezione anti-falsificazione accesa" do
    around do |example|
      originale = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true
      example.run
    ensure
      ActionController::Base.allow_forgery_protection = originale
    end

    it "porta il token buono per ogni indirizzo" do
      render_inline(described_class.new)

      campo = page.native.at_css("input[name='authenticity_token']")
      expect(campo).to be_present
      expect(campo["value"]).to be_present
    end
  end

  # Il dialog condiviso: il motivo obbligatorio sta in pagina una volta, non una per riga.
  it "con un blocco prende i campi e resta visibile" do
    render_inline(described_class.new(id: "reason-form", hidden: false)) do
      "<textarea name='reason'></textarea>".html_safe
    end

    expect(page).to have_css("form#reason-form textarea[name='reason']")
    expect(page).to have_no_css("form.hidden", visible: :all)
  end

  it "senza protezione attiva non porta campi inutili" do
    render_inline(described_class.new)

    expect(page).to have_no_css("input[name='authenticity_token']", visible: :all)
  end
end
