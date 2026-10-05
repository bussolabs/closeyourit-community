# frozen_string_literal: true

require "rails_helper"

# CYRA-812 — il perimetro congelato all'invio è un TETTO, non un lasciapassare: al momento in cui
# il lavoro gira va rimesso a confronto con quello che l'attore vede davvero adesso.
RSpec.describe Authorization::ScopeSnapshot do
  let(:org) { create(:organization) }
  let(:account) { create(:account) }
  let(:group) { create(:group, organization: org) }
  let(:project) { create(:project, organization: org) }

  def member! = create(:membership, account: account, organization: org, role: :member)
  def owner! = create(:membership, account: account, organization: org, role: :owner)

  describe ".capture" do
    it "fotografa progetti, gruppi e accesso pieno di chi sta chiedendo" do
      member!
      create(:project_membership, account: account, project: project)
      create(:group_membership, account: account, group: group)

      snapshot = described_class.capture(account: account, organization: org)

      expect(snapshot).to have_attributes(project_ids: [ project.id ], group_ids: [ group.id ],
                                          full_access: false, reduced: false)
    end

    it "segna l'accesso pieno dell'owner tenendo comunque l'elenco esplicito" do
      owner!
      project
      group

      snapshot = described_class.capture(account: account, organization: org)

      expect(snapshot.full_access).to be(true)
      expect(snapshot.project_ids).to contain_exactly(project.id)
      expect(snapshot.group_ids).to contain_exactly(group.id)
    end
  end

  # Il caso che rende necessario dirlo invece di dedurlo: un owner di un'organizzazione ancora vuota
  # produce un elenco vuoto identico a quello con cui i lavori vecchi dicevano «tutta l'organizzazione».
  describe "l'elenco dichiarato per intero" do
    it "resta vuoto anche per l'owner, e non raccoglie i progetti nati dopo" do
      owner!
      snapshot = described_class.capture(account: account, organization: org)

      create(:project, organization: org)
      narrowed = snapshot.narrow(account: account, organization: org)

      expect(narrowed.project_ids).to be_empty
      expect(narrowed).not_to be_reduced
    end

    it "vale anche quando arriva da un lavoro in coda che lo dichiara" do
      owner!
      snapshot = described_class.frozen(project_ids: [], group_ids: [], full_access: true, listed: true)

      create(:project, organization: org)
      narrowed = snapshot.narrow(account: account, organization: org)

      expect(narrowed.project_ids).to be_empty
    end
  end

  describe "#narrow" do
    it "toglie il progetto a cui l'accesso è stato revocato dopo l'invio" do
      member!
      altro = create(:project, organization: org)
      create(:project_membership, account: account, project: project)
      create(:project_membership, account: account, project: altro)
      snapshot = described_class.capture(account: account, organization: org)

      Connections::ProjectMembership.find_by(account: account, project: altro).destroy!
      narrowed = snapshot.narrow(account: account, organization: org)

      expect(narrowed.project_ids).to contain_exactly(project.id)
      expect(narrowed).to be_reduced
    end

    it "toglie il gruppo a cui l'accesso è stato revocato dopo l'invio" do
      member!
      create(:group_membership, account: account, group: group)
      snapshot = described_class.capture(account: account, organization: org)

      Connections::GroupMembership.find_by(account: account, group: group).destroy!
      narrowed = snapshot.narrow(account: account, organization: org)

      expect(narrowed.group_ids).to be_empty
      expect(narrowed).to be_reduced
    end

    # La revoca dell'intera membership è il caso del ticket: l'account resta nell'organizzazione
    # per altre vie ma il progetto non è più suo.
    it "svuota il perimetro quando non resta nulla di visibile" do
      member!
      create(:project_membership, account: account, project: project)
      snapshot = described_class.capture(account: account, organization: org)

      Connections::ProjectMembership.find_by(account: account, project: project).destroy!
      narrowed = snapshot.narrow(account: account, organization: org)

      expect(narrowed.project_ids).to be_empty
      expect(narrowed.group_ids).to be_empty
      expect(narrowed).to be_reduced
    end

    it "spegne l'accesso pieno quando l'owner non è più owner" do
      membership = owner!
      project
      snapshot = described_class.capture(account: account, organization: org)

      membership.update!(role: :member)
      narrowed = snapshot.narrow(account: account, organization: org)

      expect(narrowed.full_access).to be(false)
      expect(narrowed.project_ids).to be_empty
      expect(narrowed).to be_reduced
    end

    it "non allarga il perimetro con i permessi arrivati dopo l'invio" do
      member!
      create(:project_membership, account: account, project: project)
      snapshot = described_class.capture(account: account, organization: org)

      nuovo = create(:project, organization: org)
      create(:project_membership, account: account, project: nuovo)
      narrowed = snapshot.narrow(account: account, organization: org)

      expect(narrowed.project_ids).to contain_exactly(project.id)
      expect(narrowed).not_to be_reduced
    end

    it "non allarga il perimetro di un owner con i progetti nati dopo l'invio" do
      owner!
      project
      snapshot = described_class.capture(account: account, organization: org)

      create(:project, organization: org)
      narrowed = snapshot.narrow(account: account, organization: org)

      expect(narrowed.project_ids).to contain_exactly(project.id)
      expect(narrowed.full_access).to be(true)
      expect(narrowed).not_to be_reduced
    end

    it "lascia il perimetro intatto quando niente è cambiato" do
      member!
      create(:project_membership, account: account, project: project)
      create(:group_membership, account: account, group: group)
      snapshot = described_class.capture(account: account, organization: org)

      narrowed = snapshot.narrow(account: account, organization: org)

      expect(narrowed.project_ids).to eq(snapshot.project_ids)
      expect(narrowed.group_ids).to eq(snapshot.group_ids)
      expect(narrowed).not_to be_reduced
    end

    it "conserva il perimetro del god che impersona, non quello dell'impersonato" do
      god = create(:account, god: true)
      member!
      snapshot = described_class.capture(account: god, organization: org)
      project

      narrowed = snapshot.narrow(account: god, organization: org)

      expect(narrowed.full_access).to be(true)
      expect(narrowed).not_to be_reduced
    end
  end

  describe ".frozen" do
    it "ricostruisce il tetto dagli argomenti di un lavoro in coda" do
      snapshot = described_class.frozen(project_ids: [ project.id ], group_ids: [ group.id ],
                                        full_access: false)

      expect(snapshot).to have_attributes(project_ids: [ project.id ], group_ids: [ group.id ],
                                          full_access: false, reduced: false)
    end

    it "accetta argomenti assenti senza inventare un perimetro" do
      snapshot = described_class.frozen(project_ids: nil, group_ids: nil, full_access: nil)

      expect(snapshot).to have_attributes(project_ids: [], group_ids: [], full_access: false)
    end

    # I lavori accodati prima di CYRA-812 salvavano l'elenco vuoto per dire «tutta l'organizzazione».
    # Quel tetto resta illimitato, ma l'intersezione con l'accesso pieno di adesso vale lo stesso.
    it "tratta l'elenco vuoto con accesso pieno come tetto sull'intera organizzazione" do
      owner!
      project
      snapshot = described_class.frozen(project_ids: [], group_ids: [], full_access: true)

      narrowed = snapshot.narrow(account: account, organization: org)

      expect(narrowed.full_access).to be(true)
      expect(narrowed.project_ids).to contain_exactly(project.id)
      expect(narrowed).not_to be_reduced
    end

    it "riduce a nulla il tetto illimitato di chi ha perso l'accesso pieno" do
      membership = owner!
      project
      snapshot = described_class.frozen(project_ids: [], group_ids: [], full_access: true)

      membership.update!(role: :member)
      narrowed = snapshot.narrow(account: account, organization: org)

      expect(narrowed.full_access).to be(false)
      expect(narrowed.project_ids).to be_empty
      expect(narrowed).to be_reduced
    end
  end
end
