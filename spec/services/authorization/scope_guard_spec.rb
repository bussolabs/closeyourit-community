# frozen_string_literal: true

require "rails_helper"

# CYRA-237 (privilege-escalation sullo SCOPE): "non puoi CONCEDERE progetti o gruppi che non vedi".
# Gemello di Authorization::GrantGuard (CYRA-156, che copre le CHIAVI): qui il confine è la
# VISIBILITÀ (Authorization::VisibleScope). #plan riconcilia richiesto+corrente sotto la visibilità
# dell'attore: preserva lo scope preesistente che non vede (né lo cancella né lo può iniettare a
# piacere) e blocca le AGGIUNTE fuori-visibilità. Solo owner/god sono unscoped → passthrough.
RSpec.describe Authorization::ScopeGuard do
  let(:org) { create(:organization) }

  def member(on: org)
    account = create(:account)
    create(:membership, account: account, organization: on, role: :member)
    account
  end

  def owner(on: org)
    account = create(:account)
    create(:membership, account: account, organization: on, role: :owner)
    account
  end

  def sees_project(account, project)
    create(:project_membership, account: account, project: project)
  end

  def sees_group(account, group)
    create(:group_membership, account: account, group: group)
  end

  def plan(actor:, project_ids: [], current_project_ids: [], group_ids: [], current_group_ids: [])
    described_class.plan(actor: actor, organization: org,
                         project_ids: project_ids, current_project_ids: current_project_ids,
                         group_ids: group_ids, current_group_ids: current_group_ids)
  end

  describe ".plan — passthrough (nessun vincolo)" do
    it "attore nil (seed/preview/system) → keep = richiesto, nessuna barriera" do
      p = create(:project, organization: org)
      result = plan(actor: nil, project_ids: [ p.id ])
      expect(result.barrier).to be_nil
      expect(result.project_ids).to contain_exactly(p.id)
    end

    it "owner (unscoped) → keep = richiesto (full-replace totale), nessuna barriera" do
      preexisting = create(:project, organization: org)
      p = create(:project, organization: org)
      result = plan(actor: owner, project_ids: [ p.id ], current_project_ids: [ preexisting.id ])
      expect(result.barrier).to be_nil
      # owner può anche rimuovere: il richiesto vince sul corrente.
      expect(result.project_ids).to contain_exactly(p.id)
    end

    it "god (unscoped) → nessuna barriera" do
      god = create(:account, god: true)
      p = create(:project, organization: org)
      result = plan(actor: god, project_ids: [ p.id ])
      expect(result.barrier).to be_nil
    end
  end

  describe ".plan — attore scoped: AGGIUNTE" do
    it "aggiungere un progetto che vede → nessuna barriera, keep lo include" do
      actor = member
      p = create(:project, organization: org)
      sees_project(actor, p)
      result = plan(actor: actor, project_ids: [ p.id ])
      expect(result.barrier).to be_nil
      expect(result.project_ids).to contain_exactly(p.id)
    end

    it "aggiungere un progetto che NON vede (non già presente) → barriera R403-ACCESS-001" do
      actor = member
      hidden = create(:project, organization: org)
      result = plan(actor: actor, project_ids: [ hidden.id ])
      expect(result.barrier).to be_a(AppError)
      expect(result.barrier.code).to eq("R403-ACCESS-001")
      expect(result.barrier.status).to eq(:forbidden)
      expect(result.barrier.details[:forbidden_project_ids]).to contain_exactly(hidden.id)
    end

    it "aggiungere un gruppo che NON vede → barriera con l'id del gruppo" do
      actor = member
      hidden = create(:group, organization: org)
      result = plan(actor: actor, group_ids: [ hidden.id ])
      expect(result.barrier).to be_a(AppError)
      expect(result.barrier.details[:forbidden_group_ids]).to contain_exactly(hidden.id)
    end

    it "vede un progetto perché sta in un gruppo che vede → nessuna barriera" do
      actor = member
      group = create(:group, organization: org)
      sees_group(actor, group)
      p = create(:project, organization: org, group: group)
      result = plan(actor: actor, project_ids: [ p.id ])
      expect(result.barrier).to be_nil
    end
  end

  describe ".plan — attore scoped: PRESERVA lo scope preesistente fuori-visibilità (fix #5)" do
    it "omettere uno scope preesistente che non vede → PRESERVATO, nessuna barriera (mai cancellato)" do
      actor = member
      hidden = create(:project, organization: org)
      result = plan(actor: actor, project_ids: [], current_project_ids: [ hidden.id ])
      expect(result.barrier).to be_nil
      expect(result.project_ids).to contain_exactly(hidden.id)
    end

    it "riconfermare uno scope preesistente che non vede NON è un'aggiunta → nessuna barriera" do
      actor = member
      hidden = create(:project, organization: org)
      result = plan(actor: actor, project_ids: [ hidden.id ], current_project_ids: [ hidden.id ])
      expect(result.barrier).to be_nil
      expect(result.project_ids).to contain_exactly(hidden.id)
    end

    it "dentro la visibilità resta full-replace: un visibile omesso viene rimosso" do
      actor = member
      visible = create(:project, organization: org)
      sees_project(actor, visible)
      result = plan(actor: actor, project_ids: [], current_project_ids: [ visible.id ])
      expect(result.barrier).to be_nil
      expect(result.project_ids).to be_empty
    end

    it "mix: aggiunge il visibile, preserva il nascosto preesistente, blocca l'aggiunta nascosta" do
      actor = member
      visible = create(:project, organization: org)
      sees_project(actor, visible)
      preexisting_hidden = create(:project, organization: org)
      new_hidden = create(:project, organization: org)
      # richiede: visibile (nuovo) + nascosto preesistente (riconferma) + nascosto nuovo (aggiunta vietata)
      result = plan(actor: actor,
                    project_ids: [ visible.id, preexisting_hidden.id, new_hidden.id ],
                    current_project_ids: [ preexisting_hidden.id ])
      expect(result.barrier).to be_a(AppError)
      expect(result.barrier.details[:forbidden_project_ids]).to contain_exactly(new_hidden.id)
    end
  end
end
