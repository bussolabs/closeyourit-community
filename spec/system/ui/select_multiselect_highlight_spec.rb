# frozen_string_literal: true

require "rails_helper"

# Regressione (review F3, Stimulus ui--select): choose() su un Ui::SelectComponent(multiple: true)
# dispatcha "change" ad ogni pick (per notificare controller esterni come ticket_platforms_controller.js
# sul cambio progetto). Il listener del "change" → sync() NON deve resettare l'evidenza
# (aria-activedescendant) alla prima opzione — deve restare sull'opzione appena scelta dall'utente.
# Prima del fix, sync() richiamava filter() (che fa anche setActiveIndex(firstVisibleIndex())) invece
# di applyActive() (che preserva l'indice) → l'evidenza saltava alla prima opzione ad ogni pick su
# TUTTI i multi-select del progetto (40+ filtri/form). Copre lo stesso Ui::SelectComponent(multiple:
# true) di spec/system/ui/select_hidden_disabled_spec.rb, ma sul contratto di persistenza
# dell'evidenza invece che su hidden/disabled. Gating js: spec/support/js_system.rb.
RSpec.describe "Ui::Select — multi-select preserva l'evidenza dopo una scelta", :js, type: :system do
  let(:org) { create(:organization, name: "Demo") }
  let!(:project) { create(:project, organization: org, name: "Storefront", key: "STR") }
  let!(:status) { create(:ticket_status, organization: org, code: "open", label: "Open", color: "amber") }
  let!(:priority) { create(:ticket_priority, organization: org, code: "medium", label: "Medium", color: "amber") }

  # 7 opzioni ordinate per position (Types::Platform.ordered = [:position, :label]) — bastano per
  # evidenziare/scegliere la 7ª (l'ultima, non la prima) e verificare che l'evidenza non torni in
  # cima dopo la scelta. Nessun ?project_id= in visita → @platforms = TUTTE quelle attive dell'org
  # (Member::TicketsController#load_form_options), quindi tutte e 7 compaiono nel select.
  let!(:platforms) do
    (0..6).map do |i|
      create(:platform, organization: org, code: "platform_#{i}", label: "Platform #{('A'.ord + i).chr}", position: i)
    end
  end

  let(:account) do
    acc = create(:account)
    create(:membership, account: acc, organization: org, role: :owner)
    acc
  end

  # Stesso helper di select_combobox_spec.rb / select_hidden_disabled_spec.rb.
  def combobox_for(test_id)
    find("select[data-test='#{test_id}']", visible: :all).find(:xpath, "..")
  end

  it "sceglie la 7ª opzione da tastiera e l'evidenza resta lì (non salta alla 1ª)" do
    sign_in_as(account)
    visit new_member_ticket_path
    expect(page).to have_css("[data-test='ticket-form']")

    combo = combobox_for("ticket-platforms")
    native = combo.find("select[data-test='ticket-platforms']", visible: :all)
    trigger = combo.find("button[aria-haspopup='listbox']")
    search = combo.find("[role='combobox']", visible: :all)

    trigger.click
    rows = combo.all("[role='option']", visible: :all)
    expect(rows.map(&:text)).to eq(platforms.map(&:label))

    first_id = rows.first[:id]
    target = platforms.last # 7ª opzione (ultima) — deliberatamente NON la prima
    target_id = combo.find("[role='option']", text: target.label, visible: :all)[:id]

    # Nessuna piattaforma preselezionata su questo profilo/progetto → l'evidenza iniziale è la 1ª
    # (initialActiveIndex()). 6 ArrowDown la spostano fino alla 7ª.
    expect(search[:"aria-activedescendant"]).to eq(first_id)
    6.times { search.send_keys(:arrow_down) }
    expect(search[:"aria-activedescendant"]).to eq(target_id)

    # Sceglie da tastiera (Enter): multi-select → choose() NON chiude il pannello e dispatcha
    # "change" (bubbles), che rientra in sync(). Prima del fix questo faceva saltare l'evidenza
    # alla 1ª opzione (sync() chiamava filter(), non applyActive()).
    search.send_keys(:enter)

    expect(trigger[:"aria-expanded"]).to eq("true") # pannello ancora aperto (contratto multi-select)
    expect(native.value).to include(target.id.to_s) # il nativo (che submette) riflette la scelta

    # L'evidenza resta sulla 7ª opzione — NON è tornata alla 1ª (il fix del finding).
    expect(search[:"aria-activedescendant"]).to eq(target_id)
    expect(search[:"aria-activedescendant"]).not_to eq(first_id)

    # Riquery fresca (renderList() ha ricreato tutte le righe: il riferimento "rows" pre-scelta è
    # stale) — stessa classe di evidenza (HIGHLIGHT) applicata da applyActive(), non solo l'ARIA.
    target_row = combo.find("##{target_id}", visible: :all)
    expect(target_row[:"aria-selected"]).to eq("true")
    expect(target_row[:class]).to include("bg-stone-100")
  end
end
