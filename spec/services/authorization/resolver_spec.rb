# frozen_string_literal: true

require "rails_helper"

# Cuore RBAC: gerarchia personale > ruoli, confini di scope, owner/god, propagazione live.
# Gli scenari rispecchiano la tabella del piano (S1–S6, S10 + org-level).
RSpec.describe Authorization::Resolver do
  let(:org) { create(:organization) }

  def member!(account, role = :member) = create(:membership, account: account, organization: org, role: role)

  def role_with(name, *keys)
    role = create(:role, organization: org, name: name)
    keys.each { |k| create(:role_permission, role: role, permission_key: k) }
    role
  end

  def resolver(account) = described_class.new(account: account, organization: org)

  describe "owner e god" do
    it "owner può tutto, senza link" do
      owner = create(:account)
      member!(owner, :owner)
      expect(resolver(owner).can?("tickets.edit", scope: create(:project, organization: org))).to be true
      expect(resolver(owner).can?("permissions.manage")).to be true
    end

    it "god può tutto, anche senza membership" do
      god = create(:account, god: true)
      expect(resolver(god).can?("members.manage")).to be true
    end
  end

  describe "S1 — ruolo del team su scope" do
    let(:mario) { create(:account) }
    let(:p1) { create(:project, organization: org) }
    let(:p2) { create(:project, organization: org) }
    let(:support) { create(:team, organization: org) }

    before do
      member!(mario)
      create(:team_membership, account: mario, team: support)
      create(:team_role, team: support, role: role_with("Maintainer", "tickets.edit"))
      create(:team_project_access, team: support, project: p1)
    end

    it "può editare i ticket su P1 (ruolo via team)" do
      expect(resolver(mario).can?("tickets.edit", scope: p1)).to be true
    end

    it "NON può su P2 (team non collegato, P2 non visibile)" do
      expect(resolver(mario).can?("tickets.edit", scope: p2)).to be false
    end

    it "non concede una chiave che il ruolo non ha" do
      expect(resolver(mario).can?("tickets.delete", scope: p1)).to be false
    end
  end

  describe "S2 — override personale deny batte il ruolo" do
    it "deny personale blocca anche se il team concede" do
      mario = create(:account)
      member!(mario)
      support = create(:team, organization: org)
      create(:team_membership, account: mario, team: support)
      create(:team_role, team: support, role: role_with("Maintainer", "tickets.edit"))
      p1 = create(:project, organization: org)
      create(:team_project_access, team: support, project: p1)
      create(:account_permission, account: mario, organization: org,
             permission_key: "tickets.edit", effect: :deny)

      decision = resolver(mario).decide("tickets.edit", scope: p1)
      expect(decision.allowed).to be false
      expect(decision.origin).to eq(:personal_deny)
    end
  end

  describe "S3 — override personale allow aggiunge oltre il ruolo" do
    it "allow personale concede una chiave non nel ruolo, ma solo nello scope visibile" do
      sara = create(:account)
      member!(sara)
      support = create(:team, organization: org)
      create(:team_membership, account: sara, team: support)
      create(:team_role, team: support, role: role_with("Maintainer", "tickets.edit"))
      p1 = create(:project, organization: org)
      p2 = create(:project, organization: org)
      create(:team_project_access, team: support, project: p1)
      create(:account_permission, account: sara, organization: org,
             permission_key: "errors.triage", effect: :allow)

      expect(resolver(sara).can?("errors.triage", scope: p1)).to be true # visibile + allow
      expect(resolver(sara).can?("errors.triage", scope: p2)).to be false # P2 non visibile
    end
  end

  describe "S4 — ruolo diretto su utente singolo (senza team)" do
    it "il ruolo diretto vale sullo scope dei link personali" do
      luca = create(:account)
      member!(luca)
      p1 = create(:project, organization: org)
      p2 = create(:project, organization: org)
      create(:project_membership, account: luca, project: p2)
      create(:account_role, account: luca, organization: org, role: role_with("Triager", "errors.triage"))

      expect(resolver(luca).can?("errors.triage", scope: p2)).to be true
      expect(resolver(luca).can?("errors.triage", scope: p1)).to be false
    end
  end

  describe "S5 — propagazione live" do
    it "aggiungere una chiave al ruolo concede subito, senza ri-assegnare" do
      mario = create(:account)
      member!(mario)
      support = create(:team, organization: org)
      create(:team_membership, account: mario, team: support)
      maintainer = role_with("Maintainer", "tickets.edit")
      create(:team_role, team: support, role: maintainer)
      p1 = create(:project, organization: org)
      create(:team_project_access, team: support, project: p1)

      expect(resolver(mario).can?("tokens.manage", scope: p1)).to be false
      create(:role_permission, role: maintainer, permission_key: "tokens.manage")
      expect(resolver(mario).can?("tokens.manage", scope: p1)).to be true # nuovo Resolver, chiavi correnti
    end
  end

  describe "S6 — scope a gruppo segue i progetti futuri" do
    it "il ruolo via team su un gruppo copre i progetti presenti e futuri del gruppo" do
      mario = create(:account)
      member!(mario)
      support = create(:team, organization: org)
      create(:team_membership, account: mario, team: support)
      create(:team_role, team: support, role: role_with("Maintainer", "tickets.edit"))
      g1 = create(:group, organization: org)
      p1 = create(:project, organization: org, group: g1)
      p2 = create(:project, organization: org) # fuori dal gruppo
      create(:team_group_access, team: support, group: g1)

      expect(resolver(mario).can?("tickets.edit", scope: p1)).to be true
      expect(resolver(mario).can?("tickets.edit", scope: p2)).to be false
      p3 = create(:project, organization: org, group: g1) # aggiunto DOPO
      expect(resolver(mario).can?("tickets.edit", scope: p3)).to be true
    end
  end

  describe "S10 — baseline: ruolo Viewer (nessuna chiave)" do
    it "vede lo scope ma non ha permessi d'azione" do
      nadia = create(:account)
      member!(nadia)
      support = create(:team, organization: org)
      create(:team_membership, account: nadia, team: support)
      create(:team_role, team: support, role: role_with("Viewer"))
      p1 = create(:project, organization: org)
      create(:team_project_access, team: support, project: p1)

      expect(Authorization::VisibleScope.new(account: nadia, organization: org).projects).to include(p1)
      expect(resolver(nadia).can?("tickets.edit", scope: p1)).to be false
      expect(resolver(nadia).can?("tickets.comment.delete_any", scope: p1)).to be false
    end
  end

  describe "permessi org-level (senza scope)" do
    it "concessi da un ruolo, indipendenti dallo scope progetto" do
      gina = create(:account)
      member!(gina)
      hr = create(:team, organization: org)
      create(:team_membership, account: gina, team: hr)
      create(:team_role, team: hr, role: role_with("People", "members.invite"))

      expect(resolver(gina).can?("members.invite")).to be true
      expect(resolver(gina).can?("permissions.manage")).to be false
    end
  end

  describe "chiave sconosciuta" do
    it "negata" do
      account = create(:account)
      member!(account)
      expect(resolver(account).can?("tickets.teleport", scope: create(:project, organization: org))).to be false
    end
  end

  # CYRA-177: permesso scoped valutato su un GRUPPO (per collegarci una pagina KB anche quando è vuoto).
  describe "#can_group? — permesso scoped su un gruppo, anche vuoto" do
    let(:group) { create(:group, organization: org) }

    it "owner e god concedono sempre" do
      owner = create(:account)
      member!(owner, :owner)
      expect(resolver(owner).can_group?("knowledge.edit", group)).to be true
      expect(resolver(create(:account, god: true)).can_group?("knowledge.edit", group)).to be true
    end

    it "concede se un ruolo personale con la chiave è collegato al gruppo" do
      account = create(:account)
      member!(account)
      create(:group_membership, account: account, group: group)
      create(:account_role, account: account, organization: org, role: role_with("Editor", "knowledge.edit"))

      expect(resolver(account).can_group?("knowledge.edit", group)).to be true
    end

    it "concede via team collegato al gruppo con la chiave" do
      account = create(:account)
      member!(account)
      support = create(:team, organization: org)
      create(:team_membership, account: account, team: support)
      create(:team_role, team: support, role: role_with("Maintainer", "knowledge.edit"))
      create(:team_group_access, team: support, group: group)

      expect(resolver(account).can_group?("knowledge.edit", group)).to be true
    end

    it "nega se il gruppo è visibile ma nessun ruolo con la chiave lo copre" do
      account = create(:account)
      member!(account)
      create(:group_membership, account: account, group: group)

      expect(resolver(account).can_group?("knowledge.edit", group)).to be false
    end

    it "nega se il gruppo non è visibile, anche con override allow" do
      account = create(:account)
      member!(account)
      create(:account_permission, account: account, organization: org, permission_key: "knowledge.edit", effect: :allow)

      expect(resolver(account).can_group?("knowledge.edit", group)).to be false
    end

    it "un deny personale batte il ruolo" do
      account = create(:account)
      member!(account)
      create(:group_membership, account: account, group: group)
      create(:account_role, account: account, organization: org, role: role_with("Editor", "knowledge.edit"))
      create(:account_permission, account: account, organization: org, permission_key: "knowledge.edit", effect: :deny)

      expect(resolver(account).can_group?("knowledge.edit", group)).to be false
    end
  end
end
