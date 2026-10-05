# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::SwitchComponent, type: :component do
  def render_switch(**opts)
    base = { name: "roadmap_enabled", url: "/projects/1/settings", label: "Roadmap" }
    render_inline(described_class.new(**base.merge(opts)))
  end

  # CYRA-563 — il controller sta sulla RIGA, non più sulla pill: l'etichetta che dichiara l'esito è
  # fratello del bottone, e Stimulus cerca i target solo dentro l'elemento del controller.
  it "rende un button role=switch dentro una riga cablata al controller ui--switch" do
    render_switch
    expect(page).to have_css('div[data-controller="ui--switch"] > button[role="switch"][type="button"]')
    expect(page).to have_css('button[data-action="ui--switch#toggle"][data-ui--switch-target="pill"]')
  end

  it "passa url e param come Stimulus values" do
    render_switch(url: "/p/1/settings", name: "quick_bug_report_enabled")
    expect(page).to have_css('div[data-ui--switch-url-value="/p/1/settings"]')
    expect(page).to have_css('div[data-ui--switch-param-value="quick_bug_report_enabled"]')
  end

  it "stato ON → aria-checked true + sfondo indigo + knob target presente" do
    render_switch(checked: true)
    expect(page).to have_css('button[role="switch"][aria-checked="true"].bg-indigo-600')
    expect(page).to have_css('button span[data-ui--switch-target="knob"]')
  end

  it "stato OFF → aria-checked false + sfondo stone" do
    render_switch(checked: false)
    expect(page).to have_css('button[role="switch"][aria-checked="false"].bg-stone-300')
  end

  it "espone label e hint" do
    render_switch(label: "Roadmap", hint: "abilita milestone")
    expect(page).to have_text("Roadmap")
    expect(page).to have_text("abilita milestone")
  end

  it "renders the icon when one is given" do
    render_switch(icon: "map")
    expect(page).to have_css("svg[data-icon='map']")
  end

  it "espone il data-test sul button" do
    render_switch(test_id: "sw-x")
    expect(page).to have_css('button[role="switch"][data-test="sw-x"]')
  end

  it "espone un focus ring visibile ad AA (indigo-500 su focus-visible)" do
    render_switch
    html = page.native.to_html
    expect(html).to include("focus-visible:ring-indigo-500")
    expect(html).not_to include("focus:ring-indigo-100")
  end

  it "collega il button al nome via aria-labelledby (nome accessibile, non solo 'switch, on')" do
    render_switch(name: "flag", label: "Attiva")
    html = page.native.to_html
    expect(html).to include('id="flag_switch_label"')
    expect(html).to include('aria-labelledby="flag_switch_label"')
  end

  it "il knob rispetta prefers-reduced-motion (motion-safe:transition, non transition nudo)" do
    render_switch
    classes = page.find("span[data-ui--switch-target='knob']")[:class].split
    expect(classes).to include("motion-safe:transition")
    expect(classes).not_to include("transition")
  end

  # CYRA-563 — nelle impostazioni del progetto questi interruttori stavano accanto a campi che
  # aspettano il Salva, identici a occhio: la riga dichiara da sola che qui non c'è da salvare.
  describe "dichiarazione del salvataggio immediato" do
    it "accanto alla pill dice che la modifica si applica subito" do
      render_switch
      stato = page.find("[data-ui--switch-target='status']")
      expect(stato.text.strip).to eq(I18n.t("ui.switch.immediate"))
    end

    it "annuncia l'esito anche a chi usa un lettore di schermo (aria-live)" do
      render_switch
      expect(page).to have_css("[data-ui--switch-target='status'][aria-live='polite']")
    end

    it "l'etichetta sta fuori dal bottone: non ne cambia il nome accessibile" do
      render_switch
      expect(page).to have_no_css("button[role='switch'] [data-ui--switch-target='status']")
    end

    # CYRA-442 — le parole che il widget si scrive da solo arrivano tradotte da qui: dentro il JS
    # nessuna scelta di lingua le raggiungerebbe.
    it "passa al controller le parole dell'esito già tradotte" do
      render_switch
      riga = page.find("[data-controller='ui--switch']")
      expect(riga["data-ui--switch-immediate-label-value"]).to eq(I18n.t("ui.switch.immediate"))
      expect(riga["data-ui--switch-saved-label-value"]).to eq(I18n.t("ui.switch.saved"))
      expect(riga["data-ui--switch-failed-label-value"]).to eq(I18n.t("ui.switch.failed"))
    end
  end

  # CYRA-883 — a page that already says it once above the switches can drop the per-row note; the
  # status slot stays, because it still reports "saved" / "not saved" after the click.
  it "without the immediate note keeps an empty status slot and still reports the outcome" do
    render_switch(immediate_note: false)
    row = page.find('div[data-controller="ui--switch"]')

    expect(row.find('[data-ui--switch-target="status"]', visible: :all).text.strip).to eq("")
    expect(row["data-ui--switch-immediate-label-value"]).to eq("")
    expect(row["data-ui--switch-saved-label-value"]).to eq(I18n.t("ui.switch.saved"))
  end
end
