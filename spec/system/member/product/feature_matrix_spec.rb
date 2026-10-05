# frozen_string_literal: true

require "rails_helper"

# Matrice funzionalità × piattaforme end-to-end (rack_test: il turbo frame della cella non viene
# processato, quindi la modifica naviga la pagina di edit — comportamento previsto e progettato).
RSpec.describe "Member product — matrice funzionalità", type: :system do
  before { driven_by(:rack_test) }

  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let!(:group) { create(:group, organization: org, name: "DriverOne") }
  let!(:platform) { create(:platform, organization: org, code: "web", label: "Web") }
  let!(:project) do
    create(:project, organization: org, group: group).tap do |project|
      Connections::ProjectPlatform.create!(project: project, platform: platform)
    end
  end

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    Types::InstallDefaults.call(organization: org)
  end

  def sign_in_as(account)
    visit login_path
    fill_test "login-email", with: account.email
    fill_test "login-password", with: "Secret123!"
    click_on_test "login-submit"
  end

  it "dal prodotto vuoto alla casella compilata con stato e versione" do
    release = create(:release, project: project, version: "1.4.0")
    sign_in_as(owner)

    # 1. La matrice parte vuota.
    visit member_product_matrices_path
    click_on_test "product-matrix-link-#{group.id}"
    expect_test "product-matrix-empty"

    # 2. Prima categoria.
    click_on_test "product-category-new"
    fill_test "product-category-name", with: "Auth"
    click_on_test "product-category-submit"
    expect(page).to have_text("Auth")

    # 3. Prima funzionalità.
    click_on_test "product-feature-new"
    fill_test "product-feature-name", with: "2FA"
    click_on_test "product-feature-submit"
    expect(page).to have_text("2FA")

    # 4. La casella Web: stato "Available" e la versione da cui è disponibile.
    feature = Product::Feature.find_by(name: "2FA")
    click_on_test "product-cell-#{feature.id}-#{platform.id}"
    find("[data-test='product-cell-status']", visible: :all)
      .find("option[value='#{org.feature_statuses.find_by(code: 'available').id}']").select_option
    find("[data-test='product-cell-release']", visible: :all)
      .find("option[value='#{release.id}']").select_option
    click_on_test "product-cell-submit"

    # 5. La matrice mostra stato e versione, e nessun avviso di versione mancante.
    expect(page).to have_text("Available")
    expect(page).to have_text("1.4.0")
    expect(page).to have_no_css("[data-test='product-matrix-count-missing-release']")
  end

  it "segnala le caselle disponibili senza versione" do
    category = create(:product_category, group: group, organization: org, name: "Auth")
    feature = create(:product_feature, category: category, organization: org, name: "2FA")
    create(:feature_platform, feature: feature, platform: platform,
                              status: org.feature_statuses.find_by(code: "available"))
    sign_in_as(owner)

    visit member_product_matrix_path(group)

    expect_test "product-matrix-count-missing-release"
  end

  it "il nome della funzionalità rimanda alla pagina che la spiega" do
    page_record = create(:knowledge_page, organization: org, title: "Come funziona il 2FA")
    category = create(:product_category, group: group, organization: org)
    feature = create(:product_feature, category: category, organization: org,
                                       name: "2FA", knowledge_page: page_record)
    sign_in_as(owner)

    visit member_product_matrix_path(group)
    click_on_test "product-feature-page-#{feature.id}"

    expect(page).to have_text("Come funziona il 2FA")
  end

  it "segna una funzionalità su una piattaforma senza progetto e la colonna compare" do
    create(:platform, organization: org, code: "ios2", label: "iPhone")
    category = create(:product_category, group: group, organization: org)
    feature = create(:product_feature, category: category, organization: org, name: "Apple login")
    sign_in_as(owner)

    visit new_member_product_feature_cell_path(feature)
    find("[data-test='product-cell-new-platform']", visible: :all)
      .find("option", text: "iPhone").select_option
    find("[data-test='product-cell-new-status']", visible: :all)
      .find("option[value='#{org.feature_statuses.find_by(code: 'planned').id}']").select_option
    click_on_test "product-cell-new-submit"

    expect(page).to have_text("iPhone")
    expect(page).to have_text("Planned")
  end

  it "avvisa quando il prodotto non dichiara nessuna piattaforma" do
    empty_group = create(:group, organization: org, name: "Senza piattaforme")
    sign_in_as(owner)

    visit member_product_matrix_path(empty_group)

    expect_test "product-matrix-no-platforms"
  end
end
