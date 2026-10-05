# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Default roles + backfill" do
  describe Authorization::InstallDefaultRoles do
    let(:org) { create(:organization) }

    it "crea i ruoli default editabili" do
      described_class.call(organization: org)
      expect(org.roles.pluck(:name)).to include("Viewer", "Triager", "Maintainer", "Administrator")
    end

    it "Administrator ha tutte le chiavi del Catalog, Viewer nessuna" do
      described_class.call(organization: org)
      admin = org.roles.find_by(name: "Administrator")
      viewer = org.roles.find_by(name: "Viewer")
      expect(admin.permission_keys).to match_array(Authorization::Catalog.keys)
      expect(viewer.permission_keys).to be_empty
    end

    it "Maintainer gestisce il vault dei secret (secrets.manage) per le org nuove" do
      described_class.call(organization: org)
      maintainer = org.roles.find_by(name: "Maintainer")
      expect(maintainer.permission_keys).to include("secrets.manage")
      expect(maintainer.permission_keys).not_to include("secrets.provision")
    end

    # CYRA-721 — da quando gestire non implica più leggere, un Maintainer senza secrets.read sarebbe un
    # ruolo che cambia valori senza poterli vedere: il ruolo di default nasce con entrambe le chiavi.
    it "Maintainer legge anche i valori dei secret (secrets.read)" do
      described_class.call(organization: org)
      expect(org.roles.find_by(name: "Maintainer").permission_keys).to include("secrets.read")
    end

    it "idempotente (ri-eseguibile senza duplicare)" do
      described_class.call(organization: org)
      expect { described_class.call(organization: org) }.not_to change { org.roles.count }
    end
  end

  describe Authorization::BackfillOrganization do
    let(:org) { create(:organization) }
    let(:admin) { create(:account) }
    let(:member) { create(:account) }

    before do
      create(:membership, account: admin, organization: org, role: :admin)
      create(:membership, account: member, organization: org, role: :member)
      @p1 = create(:project, organization: org)
      @g1 = create(:group, organization: org)
      @p2 = create(:project, organization: org, group: @g1)
    end

    it "crea il team Administrators con ruolo Administrator, collegato a tutti i progetti/gruppi" do
      described_class.call(organization: org)
      team = org.teams.find_by(name: "Administrators")
      expect(team).to be_present
      expect(team.roles.pluck(:name)).to contain_exactly("Administrator")
      expect(team.scoped_projects).to include(@p1, @p2)
      expect(team.scoped_groups).to include(@g1)
    end

    it "aggiunge gli account admin al team, non i member" do
      described_class.call(organization: org)
      team = org.teams.find_by(name: "Administrators")
      expect(team.members).to include(admin)
      expect(team.members).not_to include(member)
    end

    it "idempotente" do
      described_class.call(organization: org)
      expect { described_class.call(organization: org) }.not_to change { org.teams.count }
    end

    it "preserva il comportamento attuale: un ex-admin vede tutti i progetti via il team" do
      described_class.call(organization: org)
      visible = Authorization::VisibleScope.new(account: admin, organization: org).projects
      expect(visible).to include(@p1, @p2)
    end
  end
end
