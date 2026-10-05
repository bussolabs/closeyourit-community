# frozen_string_literal: true

require "rails_helper"

# Rendering delle pagine (rack_test, no-JS). La creazione dataset richiede lo Stimulus datasets-columns
# per aggiungere le colonne Input/Target → coperta dal request spec (param esatti) e dalla verifica
# browser della fase finale.
RSpec.describe "Member datasets", type: :system do
  before { driven_by(:rack_test) }

  let(:org) { create(:organization, name: "Demo") }
  let(:owner) { create(:account, name: "Ada Owner") }
  let(:project) { create(:project, organization: org, name: "Ispezione", key: "ISP") }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    project
  end

  def sign_in_as(account)
    visit login_path
    fill_test "login-email", with: account.email
    fill_test "login-password", with: "Secret123!"
    click_on_test "login-submit"
  end

  it "mostra la voce nel gruppo Automazione e l'index vuoto" do
    sign_in_as(owner)
    visit member_datasets_path

    expect_test "member-nav-group-automation"
    expect_test "member-nav-datasets"
    expect_test "datasets-empty"
  end

  it "renderizza il form con nome, progetto e aggiunta colonne" do
    sign_in_as(owner)
    visit new_member_dataset_path

    expect_test "datasets-form-name"
    expect_test "datasets-form-project"
    expect_test "datasets-form-add-column"
  end

  it "mostra lo schema (Input/Target) e la sezione righe di un dataset esistente" do
    dataset = create(:dataset, project: project, name: "Copertine")
    create(:dataset_column, :photo, dataset: dataset, code: "cover")
    create(:dataset_column, :target, dataset: dataset, code: "evento", kind: :boolean)
    sign_in_as(owner)

    visit member_dataset_path(dataset)

    expect_test "dataset-schema"
    expect_test "dataset-rows"
    expect_test "dataset-row-new"
  end
end
