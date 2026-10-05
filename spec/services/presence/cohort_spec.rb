# frozen_string_literal: true

require "rails_helper"

# Presence::Cohort — filtro di visibilità della presenza. Confini coperti (rules/test-boundaries):
#  - self sempre visibile; 0 assegnazioni → solo sé (+ owner);
#  - condivisione 1/N via progetto diretto / gruppo / espansione gruppo→progetti /
#    TeamProjectAccess / TeamGroupAccess / stesso team (senza risorse);
#  - NON condivisione → invisibile;
#  - owner online sempre visibile ai member; viewer unscoped (owner/god) vede tutti;
#  - admin trattato come scoped (nuovo regime); isolamento tenant (contesti di altra org non contano).
RSpec.describe Presence::Cohort do
  let(:org) { create(:organization) }

  def cohort(online) = described_class.new(organization: org, online: online)
  def visible_ids(viewer, online) = cohort(online).visible_for(viewer).map(&:id)

  # Account membro dell'org con un dato ruolo (default member).
  def member(name, role: :member)
    account = create(:account, name: name)
    create(:membership, account: account, organization: org, role: role)
    account
  end

  describe "viewer scoped (member)" do
    it "con insieme online VUOTO non vede nessuno (build_footprints esce su online vuoto)" do
      viewer = member("Viewer")
      expect(visible_ids(viewer, [])).to eq([])
    end

    it "con zero assegnazioni vede SOLO sé stesso (self sempre incluso)" do
      viewer = member("Viewer")
      other  = member("Other") # nessun contesto in comune
      expect(visible_ids(viewer, [ viewer, other ])).to contain_exactly(viewer.id)
    end

    it "NON vede un peer con cui non condivide alcun progetto" do
      viewer  = member("Viewer")
      peer    = member("Peer")
      project_a = create(:project, organization: org)
      project_b = create(:project, organization: org)
      create(:project_membership, account: viewer, project: project_a)
      create(:project_membership, account: peer,   project: project_b)

      expect(visible_ids(viewer, [ viewer, peer ])).to contain_exactly(viewer.id)
    end

    it "vede un peer che condivide un progetto DIRETTO" do
      viewer = member("Viewer")
      peer   = member("Peer")
      project = create(:project, organization: org)
      create(:project_membership, account: viewer, project: project)
      create(:project_membership, account: peer,   project: project)

      expect(visible_ids(viewer, [ viewer, peer ])).to contain_exactly(viewer.id, peer.id)
    end

    it "vede un peer che condivide un GRUPPO diretto" do
      viewer = member("Viewer")
      peer   = member("Peer")
      group = create(:group, organization: org)
      create(:group_membership, account: viewer, group: group)
      create(:group_membership, account: peer,   group: group)

      expect(visible_ids(viewer, [ viewer, peer ])).to contain_exactly(viewer.id, peer.id)
    end

    it "vede un peer via ESPANSIONE gruppo→progetti (viewer sul gruppo, peer sul progetto del gruppo)" do
      viewer = member("Viewer")
      peer   = member("Peer")
      group = create(:group, organization: org)
      project = create(:project, organization: org, group: group)
      create(:group_membership,   account: viewer, group: group)   # viewer vede tutti i progetti del gruppo
      create(:project_membership, account: peer,   project: project) # peer vede il singolo progetto

      expect(visible_ids(viewer, [ viewer, peer ])).to contain_exactly(viewer.id, peer.id)
    end

    it "vede un peer via TeamProjectAccess (viewer nel team con accesso al progetto, peer diretto)" do
      viewer = member("Viewer")
      peer   = member("Peer")
      team = create(:team, organization: org)
      project = create(:project, organization: org)
      create(:team_membership,     account: viewer, team: team)
      create(:team_project_access, team: team, project: project)
      create(:project_membership,  account: peer,   project: project)

      expect(visible_ids(viewer, [ viewer, peer ])).to contain_exactly(viewer.id, peer.id)
    end

    it "vede un peer via TeamGroupAccess (viewer nel team con accesso al gruppo, peer sul gruppo)" do
      viewer = member("Viewer")
      peer   = member("Peer")
      team = create(:team, organization: org)
      group = create(:group, organization: org)
      create(:team_membership,   account: viewer, team: team)
      create(:team_group_access, team: team, group: group)
      create(:group_membership,  account: peer,  group: group)

      expect(visible_ids(viewer, [ viewer, peer ])).to contain_exactly(viewer.id, peer.id)
    end

    it "vede un peer che è nel suo STESSO team (anche senza accesso a risorse)" do
      viewer = member("Viewer")
      peer   = member("Peer")
      team = create(:team, organization: org)
      create(:team_membership, account: viewer, team: team)
      create(:team_membership, account: peer,   team: team)

      expect(visible_ids(viewer, [ viewer, peer ])).to contain_exactly(viewer.id, peer.id)
    end

    it "vede SEMPRE un owner online (staff dell'org), senza contesti in comune" do
      viewer = member("Viewer")
      boss   = member("Boss", role: :owner)
      expect(visible_ids(viewer, [ viewer, boss ])).to contain_exactly(viewer.id, boss.id)
    end

    it "vede l'UNIONE dei co-membri (N via meccanismi diversi) ma non gli estranei" do
      viewer = member("Viewer")
      by_project = member("ByProject")
      by_team    = member("ByTeam")
      stranger   = member("Stranger")

      project = create(:project, organization: org)
      create(:project_membership, account: viewer,     project: project)
      create(:project_membership, account: by_project, project: project)

      team = create(:team, organization: org)
      create(:team_membership, account: viewer,  team: team)
      create(:team_membership, account: by_team, team: team)

      online = [ viewer, by_project, by_team, stranger ]
      expect(visible_ids(viewer, online)).to contain_exactly(viewer.id, by_project.id, by_team.id)
    end
  end

  describe "viewer scoped (admin) — demoto: trattato come member" do
    it "NON vede un peer con cui non condivide contesti" do
      admin = member("Admin", role: :admin)
      peer  = member("Peer")
      expect(visible_ids(admin, [ admin, peer ])).to contain_exactly(admin.id)
    end
  end

  describe "viewer unscoped" do
    it "owner vede TUTTI gli online (nessun contesto richiesto)" do
      boss = member("Boss", role: :owner)
      m1   = member("M1")
      m2   = member("M2")
      expect(visible_ids(boss, [ boss, m1, m2 ])).to contain_exactly(boss.id, m1.id, m2.id)
    end

    it "god vede TUTTI gli online" do
      god = create(:account, name: "God", god: true)
      m1  = member("M1")
      m2  = member("M2")
      expect(visible_ids(god, [ god, m1, m2 ])).to contain_exactly(god.id, m1.id, m2.id)
    end
  end

  describe "isolamento tenant" do
    it "un owner di UN'ALTRA org non è trattato come owner qui" do
      other_org = create(:organization)
      viewer    = member("Viewer")
      # boss è owner in other_org ma solo member (o niente) in questa org
      boss = create(:account, name: "OtherBoss")
      create(:membership, account: boss, organization: other_org, role: :owner)
      create(:membership, account: boss, organization: org, role: :member)

      expect(visible_ids(viewer, [ viewer, boss ])).to contain_exactly(viewer.id)
    end

    it "un progetto omonimo in un'altra org non crea condivisione" do
      other_org = create(:organization)
      viewer = member("Viewer") # membro di org
      peer   = member("Peer")   # membro di org
      create(:project_membership, account: viewer, project: create(:project, organization: org))
      # peer è collegato SOLO a un progetto di un'ALTRA org → nessun contesto in comune in `org`
      create(:project_membership, account: peer, project: create(:project, organization: other_org))

      expect(visible_ids(viewer, [ viewer, peer ])).to contain_exactly(viewer.id)
    end
  end
end
