# frozen_string_literal: true

require "rails_helper"

# Verifica comportamentale della semantica combobox WAI-ARIA + navigazione da tastiera dello
# Stimulus `ui--select` (regola forms-select, WP2.7). Richiede un browser reale (Stimulus deve
# connettersi): il gating js (`js: true` → driver Chrome headless + skip se manca Chrome) è
# condiviso in `spec/support/js_system.rb`; opt-in esplicito `JS_SYSTEM_SPECS=1`.
RSpec.describe "Ui::Select — combobox ARIA + tastiera", :js, type: :system do
  let(:org) { create(:organization, name: "Demo") }
  let!(:project) { create(:project, organization: org, name: "Storefront", key: "STR") }
  let!(:open_status) { create(:ticket_status, organization: org, code: "open", label: "Open", color: "amber") }
  let!(:closed_status) { create(:ticket_status, organization: org, code: "closed", label: "Closed", color: "gray") }
  # CYRA-398 — in creazione lo stato non è più una select (una sola risposta sensata): lo specimen
  # di questo spec, che verifica il COMPONENTE e non il campo, è la priorità, che di scelte ne ha.
  let!(:priority) { create(:ticket_priority, organization: org, code: "medium", label: "Medium", color: "amber") }
  let!(:high_priority) { create(:ticket_priority, organization: org, code: "high", label: "High", color: "orange") }

  let(:account) do
    acc = create(:account)
    create(:membership, account: acc, organization: org, role: :owner)
    acc
  end

  # Contenitore Stimulus (div .relative) del select con quel data-test sul <select> nativo.
  def combobox_for(test_id)
    find("select[data-test='#{test_id}']", visible: :all).find(:xpath, "..")
  end

  it "arricchisce il <select> in un combobox WAI-ARIA e naviga/seleziona da tastiera" do
    sign_in_as(account)
    visit new_member_ticket_path
    expect(page).to have_css("[data-test='ticket-form']")

    combo = combobox_for("ticket-priority")

    # Il nativo resta nel DOM (mantiene il name → submette), ma fuori dagli AT e dal tab order.
    native = combo.find("select[data-test='ticket-priority']", visible: :all)
    expect(native[:"aria-hidden"]).to eq("true")
    expect(native[:tabindex]).to eq("-1")

    # Trigger = disclosure button collegato al listbox, chiuso.
    trigger = combo.find("button[aria-haspopup='listbox']")
    listbox_id = trigger[:"aria-controls"]
    expect(listbox_id).to be_present
    expect(trigger[:"aria-expanded"]).to eq("false")

    # Listbox + combobox presenti con gli id/ruoli attesi (il combobox è nel pannello, nascosto).
    listbox = combo.find("##{listbox_id}", visible: :all)
    expect(listbox[:role]).to eq("listbox")
    search = combo.find("[role='combobox']", visible: :all)
    expect(search[:"aria-controls"]).to eq(listbox_id)
    expect(search[:"aria-autocomplete"]).to eq("list")
    # Nome accessibile agganciato alla <label> del campo (aria-labelledby → "Status").
    labelledby = search[:"aria-labelledby"]
    expect(labelledby).to be_present
    expect(find("##{labelledby}", visible: :all)).to have_text("Priority")

    # Ogni opzione è role=option con id univoco e aria-selected coerente.
    options = combo.all("[role='option']", visible: :all)
    expect(options.size).to eq(2)
    expect(options.map { |o| o[:role] }.uniq).to eq([ "option" ])

    # Il nativo required senza blank pre-seleziona la prima opzione: leggiamo la selezione iniziale
    # a runtime (l'ordine dei Types non è garantito) e puntiamo all'ALTRO stato come target.
    initial_value = native.value
    target = [ priority, high_priority ].find { |p| p.id.to_s != initial_value }

    # Apertura DA TASTIERA (ArrowDown sul trigger) → aria-expanded sincronizzato su trigger e combobox.
    trigger.send_keys(:arrow_down)
    expect(combo).to have_css("[role='combobox']", visible: true)
    expect(trigger[:"aria-expanded"]).to eq("true")
    expect(search[:"aria-expanded"]).to eq("true")
    # All'apertura l'evidenza è sull'opzione selezionata → aria-activedescendant valorizzato.
    expect(search[:"aria-activedescendant"]).to be_present

    # Con 2 opzioni, ArrowDown dalla selezionata evidenzia l'altra; Enter la seleziona
    # (single → chiude + riporta il focus al trigger).
    search.send_keys(:arrow_down)
    search.send_keys(:enter)

    expect(trigger).to have_text(target.label)
    expect(trigger[:"aria-expanded"]).to eq("false")
    # Il <select> nativo (che submette) riflette la scelta fatta col widget.
    expect(native.value).to eq(target.id.to_s)
    # aria-selected segue la selezione sull'opzione scelta. Il pannello è chiuso qui (single-select
    # → close() dopo la scelta, contratto tastiera): le righe sono dentro un antenato con classe
    # "hidden" (display:none), quindi `.text` risulta SEMPRE vuoto per elementi non renderizzati —
    # matchare sul rendered text qui è un falso negativo garantito, non un segnale di regressione.
    # `data-label` è un attributo DOM piatto (opt.textContent.toLowerCase(), impostato da
    # renderList() in select_controller.js), indifferente alla visibilità: stesso identificativo
    # semantico del testo reso, ma leggibile anche a pannello chiuso.
    chosen = combo.all("[role='option']", visible: :all).find { |o| o[:"data-label"] == target.label.downcase }
    expect(chosen[:"aria-selected"]).to eq("true")
  end

  it "Escape chiude il pannello e riporta il focus al trigger" do
    sign_in_as(account)
    visit new_member_ticket_path
    expect(page).to have_css("[data-test='ticket-form']")

    combo = combobox_for("ticket-priority")
    trigger = combo.find("button[aria-haspopup='listbox']")

    trigger.send_keys(:arrow_down)
    expect(trigger[:"aria-expanded"]).to eq("true")

    combo.find("[role='combobox']").send_keys(:escape)
    expect(trigger[:"aria-expanded"]).to eq("false")
    # Il focus è tornato al trigger.
    expect(page.evaluate_script("document.activeElement === arguments[0]", trigger.native)).to be(true)
  end

  # Nome accessibile calcolato da aria-label (letterale) o aria-labelledby (catena di id) — qualunque
  # meccanismo usi il combobox potenziato per esporlo (fix review WP5 T9, finding 1).
  def accessible_name_of(node)
    return node[:"aria-label"] if node[:"aria-label"].present?

    ids = node[:"aria-labelledby"].to_s.split
    return nil if ids.empty?

    ids.map { |id| find("##{id}", visible: :all).text }.join(" ").strip
  end

  it "select senza <label> visibile ma con aria-label: il trigger potenziato eredita il nome accessibile" do
    sign_in_as(account)
    visit member_notification_preferences_path
    expect(page).to have_css("[data-test='alerting-preferences-form']")

    # Cadenza email di "ticket_created": cella densa di tabella, MAI un <label for> — solo aria_label
    # (vedi app/views/member/alerting_preferences/_cadence_select.html.erb).
    combo = combobox_for("pref-email-ticket_created")
    native = combo.find("select[data-test='pref-email-ticket_created']", visible: :all)
    expected_name = native[:"aria-label"]
    expect(expected_name).to be_present

    # Nessuna <label for> associata a questo select.
    expect(combo.find(:xpath, "..")).to have_no_css("label[for='#{native[:id]}']")

    trigger = combo.find("button[aria-haspopup='listbox']")
    search = combo.find("[role='combobox']", visible: :all)

    # Il combobox di ricerca referenzia SOLO il nome (nessun valore concatenato) → uguaglianza esatta.
    expect(accessible_name_of(search)).to eq(expected_name)
    # Il trigger referenzia "<nome> <valore corrente>" (stesso contratto del caso <label for>,
    # vedi comment "Nome accessibile" in buildTrigger()) → il nome deve comparire in testa.
    expect(accessible_name_of(trigger)).to start_with(expected_name)
  end

  it "espone e seleziona anche un'opzione vuota dichiarata direttamente nelle options" do
    create(:alerting_preference, account:, organization: org,
           min_level: Errors::Group.levels.fetch("warning"))
    sign_in_as(account)
    visit member_notification_preferences_path

    combo = combobox_for("pref-min-level")
    native = combo.find("select[data-test='pref-min-level']", visible: :all)
    trigger = combo.find("button[aria-haspopup='listbox']")
    trigger.click

    combo.find("[role='option']", text: I18n.t("member.alerting.preferences.min_level_any")).click

    expect(native.value).to eq("")
    expect(trigger).to have_text(I18n.t("member.alerting.preferences.min_level_any"))
  end

  it "rende selezionabile un include_blank senza etichetta usando il placeholder predefinito" do
    sign_in_as(account)
    visit member_notification_preferences_path

    combo = combobox_for("pref-quiet-from")
    native = combo.find("select[data-test='pref-quiet-from']", visible: :all)
    trigger = combo.find("button[aria-haspopup='listbox']")

    trigger.click
    combo.find("[role='option']", text: "01:00").click
    expect(native.value).to eq("1")

    trigger.click
    combo.find("[role='option']", text: "Select…").click

    expect(native.value).to eq("")
    expect(trigger).to have_text("Select…")
  end
end
