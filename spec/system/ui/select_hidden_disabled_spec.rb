# frozen_string_literal: true

require "rails_helper"

# Ui::SelectComponent (Stimulus ui--select) rispetta option hidden/disabled — parità col <select>
# nativo che avvolge — e si ri-sincronizza quando un altro controller le muta IMPERATIVAMENTE
# (option.hidden/.disabled senza un "change" nativo) dispatchando "ui--select:refresh" sul <select>.
# Copre il generico (indipendente da milestone/dataset, che hanno le loro integrazioni dedicate):
# spec/system/member/ticket_milestone_select_spec.rb e spec/system/member/datasets_column_role_select_spec.rb.
# Richiede un browser reale (Stimulus deve connettersi): gating js in spec/support/js_system.rb.
RSpec.describe "Ui::Select — option hidden/disabled + refresh", :js, type: :system do
  let(:org) { create(:organization, name: "Demo") }
  let!(:project) { create(:project, organization: org, name: "Storefront", key: "STR") }
  # CYRA-398 — in creazione lo stato non è più una select: lo specimen di questo spec, che verifica
  # il COMPONENTE e non il campo, sono le priorità, che di scelte ne hanno.
  let!(:status) { create(:ticket_status, organization: org, code: "open", label: "Open", color: "amber", position: 0) }
  let!(:alpha) { create(:ticket_priority, organization: org, code: "alpha", label: "Alpha", color: "amber", position: 0) }
  let!(:beta)  { create(:ticket_priority, organization: org, code: "beta",  label: "Beta",  color: "sky",   position: 1) }
  let!(:gamma) { create(:ticket_priority, organization: org, code: "gamma", label: "Gamma", color: "gray",  position: 2) }

  let(:account) do
    acc = create(:account)
    create(:membership, account: acc, organization: org, role: :owner)
    acc
  end

  # Contenitore Stimulus (div .relative) del select con quel data-test sul <select> nativo (stesso
  # helper di select_combobox_spec.rb).
  def combobox_for(test_id)
    find("select[data-test='#{test_id}']", visible: :all).find(:xpath, "..")
  end

  it "non mostra un'option hidden e non rende selezionabile (mouse/tastiera) un'option disabled, dopo un refresh" do
    sign_in_as(account)
    visit new_member_ticket_path
    expect(page).to have_css("[data-test='ticket-form']")

    combo = combobox_for("ticket-priority")
    native = combo.find("select[data-test='ticket-priority']", visible: :all)
    trigger = combo.find("button[aria-haspopup='listbox']")
    search = combo.find("[role='combobox']", visible: :all)

    # Precondizione: nessuna mutazione ancora applicata → le 3 opzioni sono tutte presenti.
    # Visibilità DEFAULT (non visible: :all): una riga con l'attributo hidden non è renderizzata
    # (display:none) → il <button> resta nel DOM ma con testo vuoto per Selenium, quindi va escluso
    # dal match invece che confuso con un'opzione "vuota" — qui nessuna è ancora hidden.
    # Alpha si sceglie ESPLICITAMENTE: quale opzione sia preselezionata è una decisione del modulo
    # (CYRA-398), e questo spec verifica il componente, non il campo.
    trigger.click
    expect(combo.all("[role='option']").map(&:text)).to contain_exactly("Alpha", "Beta", "Gamma")
    combo.find("[role='option']", text: "Alpha").click
    expect(native.value).to eq(alpha.id.to_s)

    # Mutazione IMPERATIVA sul <select> nativo (come farebbe un controller esterno: milestone,
    # ruolo dataset) — Beta hidden, Gamma disabled — poi dispatch dell'evento di refresh.
    page.execute_script(<<~JS, native.native)
      const select = arguments[0]
      const beta = Array.from(select.options).find((o) => o.textContent === "Beta")
      const gamma = Array.from(select.options).find((o) => o.textContent === "Gamma")
      beta.hidden = true
      gamma.disabled = true
      select.dispatchEvent(new CustomEvent("ui--select:refresh"))
    JS

    trigger.click
    # Beta (hidden) non è renderizzata affatto nella lista (visibilità DEFAULT: la esclude).
    rows = combo.all("[role='option']")
    expect(rows.map(&:text)).to contain_exactly("Alpha", "Gamma")

    # Gamma (disabled) resta invece VISIBILE ma non selezionabile — per leggere il suo
    # aria-disabled/id serve visible: :all solo perché è comunque presente e visibile qui
    # (nessuna differenza pratica, coerenza con l'idioma del file).
    gamma_row = combo.find("[role='option']", text: "Gamma", visible: :all)
    expect(gamma_row[:"aria-disabled"]).to eq("true")

    # Click (anche sintetico via JS, per non dipendere da quirk di interactability WebDriver sui
    # bottoni disabled) non seleziona Gamma: trigger e nativo restano su Alpha.
    page.execute_script("arguments[0].click()", gamma_row.native)
    expect(trigger).to have_text("Alpha")
    expect(native.value).to eq(alpha.id.to_s)

    # Tastiera: con Beta hidden e Gamma disabled, l'unica opzione raggiungibile è Alpha —
    # ArrowDown non sposta mai l'evidenza su Gamma (visibleIndices esclude gli option disabled).
    search.send_keys(:arrow_down)
    active_id = search[:"aria-activedescendant"]
    alpha_row = combo.find("[role='option']", text: "Alpha")
    expect(active_id).to eq(alpha_row[:id])

    # Alpha resta scelta normalmente (il widget continua a funzionare per le opzioni non mutate).
    alpha_row.click
    expect(trigger).to have_text("Alpha")
    expect(native.value).to eq(alpha.id.to_s)
  end

  it "un'option ridiventa selezionabile dopo un secondo refresh che la riabilita" do
    sign_in_as(account)
    visit new_member_ticket_path

    combo = combobox_for("ticket-priority")
    native = combo.find("select[data-test='ticket-priority']", visible: :all)
    trigger = combo.find("button[aria-haspopup='listbox']")

    # Si parte da una scelta ESPLICITA diversa da Beta: quale opzione sia preselezionata la decide
    # il modulo (CYRA-398), e qui conta solo che Beta non sia già scelta prima di disabilitarla.
    trigger.click
    combo.find("[role='option']", text: "Alpha").click
    expect(native.value).to eq(alpha.id.to_s)

    page.execute_script(<<~JS, native.native)
      const select = arguments[0]
      const beta = Array.from(select.options).find((o) => o.textContent === "Beta")
      beta.disabled = true
      select.dispatchEvent(new CustomEvent("ui--select:refresh"))
    JS

    trigger.click
    beta_row = combo.find("[role='option']", text: "Beta", visible: :all)
    page.execute_script("arguments[0].click()", beta_row.native)
    expect(trigger).to have_no_text("Beta")
    trigger.click # richiude

    page.execute_script(<<~JS, native.native)
      const select = arguments[0]
      const beta = Array.from(select.options).find((o) => o.textContent === "Beta")
      beta.disabled = false
      select.dispatchEvent(new CustomEvent("ui--select:refresh"))
    JS

    trigger.click
    combo.find("[role='option']", text: "Beta", visible: :all).click
    expect(trigger).to have_text("Beta")
    expect(native.value).to eq(beta.id.to_s)
  end
end
