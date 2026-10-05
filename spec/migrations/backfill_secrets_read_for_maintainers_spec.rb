# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260902160000_backfill_secrets_read_for_maintainers")

RSpec.describe BackfillSecretsReadForMaintainers do
  def run_backfill
    ActiveRecord::Migration.suppress_messages { described_class.new.up }
  end

  # Il ruolo Maintainer delle org già esistenti è nato con `secrets.manage` e senza `secrets.read`:
  # finché manage implicava read non se ne accorgeva nessuno. Dal momento in cui le due chiavi sono
  # separate (CYRA-721), quello stesso ruolo smetterebbe di vedere i valori che vedeva ieri — perciò
  # `legacy!` riproduce lo stato di allora e il backfill deve ripristinarlo.
  let(:org) { create(:organization) }

  def legacy!(organization)
    Authorization::InstallDefaultRoles.call(organization: organization)
    role = organization.roles.find_by!(name: "Maintainer")
    Authorization::RolePermission.where(role_id: role.id, permission_key: "secrets.read").delete_all
    role
  end

  it "concede secrets.read ai ruoli Maintainer che avevano solo secrets.manage" do
    maintainer = legacy!(org)
    expect(maintainer.permission_keys).to include("secrets.manage")

    run_backfill

    expect(maintainer.reload.permission_keys).to include("secrets.read")
  end

  it "è idempotente (rieseguibile senza duplicare)" do
    maintainer = legacy!(org)

    2.times { run_backfill }

    expect(Authorization::RolePermission.where(role_id: maintainer.id, permission_key: "secrets.read").count).to eq(1)
  end

  # Il backfill rispecchia InstallDefaultRoles: tocca il solo ruolo Maintainer. Gli altri restano come
  # sono — dare una chiave `dangerous` a un ruolo che non l'ha mai avuta sarebbe un'escalation silenziosa.
  it "non tocca gli altri ruoli di default" do
    legacy!(org)

    run_backfill

    %w[Viewer Triager].each do |name|
      expect(org.roles.find_by!(name: name).permission_keys).not_to include("secrets.read")
    end
  end

  it "copre tutte le organizzazioni esistenti" do
    other = create(:organization)
    [ org, other ].each { |organization| legacy!(organization) }

    run_backfill

    [ org, other ].each do |organization|
      expect(organization.roles.find_by!(name: "Maintainer").permission_keys).to include("secrets.read")
    end
  end
end
