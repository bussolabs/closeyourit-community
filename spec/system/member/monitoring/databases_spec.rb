# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member database inventory", type: :system do
  before { driven_by(:rack_test) }

  let(:org) { create(:organization, name: "Demo") }

  def sign_in_as(account)
    visit login_path
    fill_test "login-email", with: account.email
    fill_test "login-password", with: "Secret123!"
    click_on_test "login-submit"
  end

  def owner_account
    account = create(:account)
    create(:membership, account: account, organization: org, role: :owner)
    account
  end

  # replicas: quante repliche il primary dichiara connesse — è il tetto di ciò che può assorbire.
  def db_host(name, databases, role: nil, replicas: 0)
    replication = { "streaming" => true,
                    "replicas" => [ { "client" => "10.0.0.12", "state" => "streaming" } ] } if replicas.positive?
    create(:server_host, :up, organization: org, name: name,
           database_snapshot: { "engine" => "postgresql", "reachable" => true, "role" => role,
                                "replication" => replication, "databases" => databases }.compact)
  end

  it "un owner apre l'inventario dalla sidebar e filtra per server" do
    db_host("db-primary", [ { "name" => "koru_production", "size_bytes" => 800 },
                            { "name" => "koru_queue_production", "size_bytes" => 200 } ])
    staging = db_host("db-staging", [ { "name" => "koru_staging", "size_bytes" => 100 } ])
    sign_in_as(owner_account)

    visit member_infrastructure_path # Databases vive accanto a Servers nella verticale Infrastructure
    click_on_test "member-nav-databases"

    expect_test "databases-table"
    expect(page).to have_text("koru_production")
    expect(page).to have_text("koru_staging")

    visit member_monitoring_databases_path(server: staging.id)

    expect(page).to have_text("koru_staging")
    expect(page).not_to have_text("koru_queue_production")
  end

  it "cercare senza scegliere un server non restringe l'elenco a una sola macchina" do
    db_host("db-primary", [ { "name" => "koru_production", "size_bytes" => 800 } ])
    db_host("db-staging", [ { "name" => "koru_staging", "size_bytes" => 100 } ])
    sign_in_as(owner_account)
    visit member_monitoring_databases_path

    # Il form del toolbar invia TUTTI i suoi campi: se il filtro server non ha uno stato "nessuna
    # scelta", una semplice ricerca testuale filtrerebbe di nascosto sul primo host dell'elenco.
    fill_test "databases-search", with: "koru"
    find("[data-test='databases-apply']", visible: :all).click

    expect(page).to have_text("koru_production")
    expect(page).to have_text("koru_staging")
  end

  it "il database presente anche sulla copia occupa una riga sola" do
    db_host("db-primary", [ { "name" => "koru_production", "size_bytes" => 800 } ], role: "primary", replicas: 1)
    standby = db_host("db-standby", [ { "name" => "koru_production", "size_bytes" => 802 } ], role: "standby")
    sign_in_as(owner_account)

    visit member_monitoring_databases_path

    expect(page).to have_css("[data-test='database-row']", count: 1)
    within_test("database-row-replicas") { expect(page).to have_text("+1") }
    expect(find("[data-test='database-row-replicas']")[:title]).to eq("db-standby")

    # La pagina della copia continua a dire cosa ospita quella macchina.
    visit member_monitoring_server_databases_path(standby)
    expect(page).to have_text("koru_production")
  end

  it "dall'elenco si apre il dettaglio di un database" do
    db_host("db-primary", [ { "name" => "koru_production", "size_bytes" => 800 } ])
    sign_in_as(owner_account)

    visit member_monitoring_databases_path
    click_on_test "database-row-link"

    expect_test "database-show"
    expect_test "database-growth"
    within_test("database-presences") { expect(page).to have_text("db-primary") }
    expect(page).to have_text("koru_production")
  end

  it "un owner passa dalla panoramica del server alla lista dei suoi database" do
    host = db_host("db-primary", [ { "name" => "koru_production", "size_bytes" => 800 } ])
    sign_in_as(owner_account)

    visit member_monitoring_server_path(host)
    click_on_test "server-tab-hardware"

    expect_test "server-databases"
    expect_test "databases-table"
    expect(page).to have_text("koru_production")
  end

  it "un member senza permesso non vede la voce Database in sidebar" do
    account = create(:account)
    create(:membership, account: account, organization: org, role: :member)
    sign_in_as(account)

    expect(page).not_to have_css("[data-test='member-nav-databases']")
  end
end
