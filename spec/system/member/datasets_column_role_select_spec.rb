# frozen_string_literal: true

require "rails_helper"

# Integrazione Parte B (F3): il select "role" di una riga colonna dataset è un Ui::SelectComponent
# searchable (regola forms-select). Una foto è sempre Input — al cambio kind (datasets-columns#
# syncRole) l'opzione "Target" viene disabilitata (mai l'intero <select>, vedi commento nel
# controller) e il widget la riflette come non selezionabile dopo il dispatch di
# "ui--select:refresh". syncRole() gira anche a connect() per le righe già kind=photo dal server
# (dataset esistente in edit). Richiede un browser reale: gating js in spec/support/js_system.rb.
RSpec.describe "Dataset form — ruolo colonna searchable, bloccato su Input per kind=photo", :js, type: :system do
  let(:org) { create(:organization, name: "Demo") }
  let!(:project) { create(:project, organization: org, name: "Ispezione", key: "ISP") }

  let(:owner) do
    acc = create(:account, name: "Ada Owner")
    create(:membership, account: acc, organization: org, role: :owner)
    acc
  end

  def combobox_for(test_id)
    find("select[data-test='#{test_id}']", visible: :all).find(:xpath, "..")
  end

  it "blocca il ruolo su Input quando l'utente sceglie kind=photo, e lo sblocca cambiando kind" do
    sign_in_as(owner)
    visit new_member_dataset_path

    click_on_test "datasets-form-add-column"
    expect(page).to have_css("[data-test='datasets-column-row']", count: 1)

    role_combo  = combobox_for("datasets-column-role")
    role_native = role_combo.find("select[data-test='datasets-column-role']", visible: :all)

    # Prima di scegliere kind=photo: Target è il ruolo di default (factory/form: nuova colonna) ed
    # è normalmente selezionabile.
    expect(role_combo.find("button[aria-haspopup='listbox']")).to have_text(I18n.t("member.datasets.form.role_target"))

    find("[data-test='datasets-column-kind']").select(I18n.t("member.datasets.kinds.photo"))

    # kind=photo → il widget mostra Input forzato, e il <select> nativo (che submette) riflette lo
    # stesso valore.
    expect(role_combo.find("button[aria-haspopup='listbox']")).to have_text(I18n.t("member.datasets.form.role_input"))
    expect(role_native.value).to eq("input")

    role_combo.find("button[aria-haspopup='listbox']").click
    target_row = role_combo.find("[role='option']", text: I18n.t("member.datasets.form.role_target"), visible: :all)
    expect(target_row[:"aria-disabled"]).to eq("true")

    # Click (sintetico via JS: un bottone disabled non è garantito interagibile da ogni driver
    # WebDriver) su Target non lo seleziona: resta Input.
    page.execute_script("arguments[0].click()", target_row.native)
    expect(role_combo.find("button[aria-haspopup='listbox']")).to have_text(I18n.t("member.datasets.form.role_input"))
    expect(role_native.value).to eq("input")

    # Cambiare kind (via, es. category) sblocca Target nel widget.
    find("[data-test='datasets-column-kind']").select(I18n.t("member.datasets.kinds.category"))
    role_combo.find("button[aria-haspopup='listbox']").click
    target_row = role_combo.find("[role='option']", text: I18n.t("member.datasets.form.role_target"))
    expect(target_row[:"aria-disabled"]).to be_nil
    target_row.click
    expect(role_combo.find("button[aria-haspopup='listbox']")).to have_text(I18n.t("member.datasets.form.role_target"))
    expect(role_native.value).to eq("target")
  end

  it "una colonna kind=photo già esistente (edit) mostra il ruolo bloccato su Input al caricamento, senza interazione" do
    dataset = create(:dataset, project: project, name: "Copertine")
    create(:dataset_column, :photo, dataset: dataset, code: "cover", label: "Cover")
    sign_in_as(owner)

    visit edit_member_dataset_path(dataset)

    role_combo  = combobox_for("datasets-column-role")
    role_native = role_combo.find("select[data-test='datasets-column-role']", visible: :all)
    expect(role_combo.find("button[aria-haspopup='listbox']")).to have_text(I18n.t("member.datasets.form.role_input"))
    expect(role_native.value).to eq("input")

    role_combo.find("button[aria-haspopup='listbox']").click
    target_row = role_combo.find("[role='option']", text: I18n.t("member.datasets.form.role_target"), visible: :all)
    expect(target_row[:"aria-disabled"]).to eq("true")
  end

  it "aggiungere due colonne dal + non produce id duplicati e i widget restano indipendenti" do
    sign_in_as(owner)
    visit new_member_dataset_path

    click_on_test "datasets-form-add-column"
    click_on_test "datasets-form-add-column"
    expect(page).to have_css("[data-test='datasets-column-row']", count: 2)

    # Il componente renderizza un id sul <select> nativo — senza il fixup di add() (che replica
    # quello già fatto per i name) due righe clonate dallo stesso <template> avrebbero lo STESSO id
    # letterale "__INDEX__" non sostituito.
    role_ids = all("select[data-test='datasets-column-role']", visible: :all).map { |el| el[:id] }
    expect(role_ids.uniq.size).to eq(2)
    expect(role_ids).to all(be_present)

    rows = all("[data-column-row]")
    row1_kind = rows[0].find("[data-test='datasets-column-kind']")
    row1_role_combo = rows[0].find("div[data-controller='ui--select']").find(:xpath, "..")
    row2_role_combo = rows[1].find("div[data-controller='ui--select']").find(:xpath, "..")

    row1_kind.select(I18n.t("member.datasets.kinds.photo"))

    # Solo il ruolo della RIGA 1 si blocca su Input; la riga 2 resta al default (Target), a riprova
    # che i due widget (e i rispettivi <select> nativi) sono scoped alla propria riga.
    expect(row1_role_combo.find("button[aria-haspopup='listbox']")).to have_text(I18n.t("member.datasets.form.role_input"))
    expect(row2_role_combo.find("button[aria-haspopup='listbox']")).to have_text(I18n.t("member.datasets.form.role_target"))
  end
end
