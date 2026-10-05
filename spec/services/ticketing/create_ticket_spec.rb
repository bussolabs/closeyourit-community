# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::CreateTicket do
  let(:org) { create(:organization) }
  let(:reporter) do
    create(:account).tap do |a|
      create(:membership, account: a, organization: org, role: :member)
      # Scoping: un member apre ticket solo su progetti assegnati.
      create(:project_membership, account: a, project: project)
    end
  end
  let(:project) { create(:project, organization: org) }
  let(:status) { create(:ticket_status, organization: org) }
  let(:priority) { create(:ticket_priority, organization: org) }

  def params(extra = {})
    {
      project_id: project.id, title: "Bug",
      scenarios_attributes: [ { step_given: "g", step_when: "w", step_then: "t", step_expected: "e" } ],
      status_id: status.id, priority_id: priority.id
    }.merge(extra)
  end

  it "crea un ticket valido (Result.ok, reporter impostato)" do
    result = described_class.call(organization: org, reporter: reporter, params: params)
    expect(result).to be_ok
    expect(result.value.reporter).to eq(reporter)
    expect(result.value.scenarios.first.step_given).to eq("g")
    expect(result.value.agent_workflow).to have_attributes(phase: "triage_queued", triage_requested_at: be_present)
  end

  it "crea N scenari BDD e le condizioni DoD dai nested attributes" do
    result = described_class.call(organization: org, reporter: reporter, params: params(
      scenarios_attributes: [
        { title: "Happy", step_given: "loggato", step_when: "compra", step_then: "ordine ok" },
        { title: "Errore", step_when: "compra", step_then: "500" }
      ],
      conditions_attributes: [ { text: "arriva la mail" }, { text: "ordine nello storico" } ],
      technical_analysis: "N+1 su Orders#create",
    ))
    expect(result).to be_ok
    expect(result.value.scenarios.map(&:title)).to eq([ "Happy", "Errore" ])
    expect(result.value.conditions.map(&:text)).to eq([ "arriva la mail", "ordine nello storico" ])
    expect(result.value.technical_analysis).to eq("N+1 su Orders#create")
  end

  it "project inesistente → Result.err R404-TICKET-001" do
    result = described_class.call(organization: org, reporter: reporter, params: params(project_id: SecureRandom.uuid))
    expect(result).to be_err
    expect(result.error.code).to eq("R404-TICKET-001")
  end

  it "project di un'altra org → err (anti-BOLA)" do
    foreign = create(:project, organization: create(:organization))
    result = described_class.call(organization: org, reporter: reporter, params: params(project_id: foreign.id))
    expect(result).to be_err
  end

  it "uno scenario con un solo step basta come corpo (Result.ok)" do
    result = described_class.call(organization: org, reporter: reporter,
      params: params(scenarios_attributes: [ { step_given: "solo contesto" } ]))
    expect(result).to be_ok
  end

  it "solo la descrizione libera (nessuno scenario) → Result.ok" do
    result = described_class.call(organization: org, reporter: reporter,
      params: params(scenarios_attributes: [], description: "Non funziona il checkout su Safari"))
    expect(result).to be_ok
    expect(result.value.description).to eq("Non funziona il checkout su Safari")
  end

  it "senza alcun corpo (né scenari né descrizione) → Result.err R422-TICKET-001" do
    result = described_class.call(organization: org, reporter: reporter,
      params: params(scenarios_attributes: [], description: ""))
    expect(result).to be_err
    expect(result.error.code).to eq("R422-TICKET-001")
  end

  it "scarta gli scenari senza alcuno step (reject_if) ma tiene i validi" do
    result = described_class.call(organization: org, reporter: reporter, params: params(
      scenarios_attributes: [
        { step_given: "valido" },
        { title: "vuoto", step_given: "", step_when: "", step_then: "", step_expected: "" }
      ],
    ))
    expect(result).to be_ok
    expect(result.value.scenarios.size).to eq(1)
  end

  it "assignee membro → assegnato" do
    member = create(:account)
    create(:membership, account: member, organization: org, role: :member)
    result = described_class.call(organization: org, reporter: reporter, params: params(assignee_id: member.id))
    expect(result.value.assignee).to eq(member)
  end

  it "reviewer auto-compilato col reporter (chi apre il ticket)" do
    result = described_class.call(organization: org, reporter: reporter, params: params)
    expect(result.value.reviewer).to eq(reporter)
  end

  it "assignee non membro → ignorato, ticket non assegnato (anti-BOLA)" do
    outsider = create(:account)
    result = described_class.call(organization: org, reporter: reporter, params: params(assignee_id: outsider.id))
    expect(result).to be_ok
    expect(result.value.assignee).to be_nil
  end

  describe "assegnatario di default (fallback progetto → team → org)" do
    # Account membro dell'org, candidabile come default a un livello della gerarchia.
    def org_member
      create(:account).tap { |a| create(:membership, account: a, organization: org) }
    end

    it "eredita il default del PROGETTO quando l'assignee non è specificato" do
      default = org_member
      project.update!(default_assignee: default)
      result = described_class.call(organization: org, reporter: reporter, params: params)
      expect(result.value.assignee).to eq(default)
    end

    it "l'assignee esplicito ha precedenza sul default del progetto" do
      default = org_member
      explicit = org_member
      project.update!(default_assignee: default)
      result = described_class.call(organization: org, reporter: reporter, params: params(assignee_id: explicit.id))
      expect(result.value.assignee).to eq(explicit)
    end

    it "eredita il default del TEAM che gestisce il progetto quando il progetto non ne ha uno" do
      team_default = org_member
      team = create(:team, organization: org, default_assignee: team_default)
      Connections::TeamProjectAccess.create!(team: team, project: project)
      result = described_class.call(organization: org, reporter: reporter, params: params)
      expect(result.value.assignee).to eq(team_default)
    end

    it "eredita il default dell'ORG quando né progetto né team ne hanno uno" do
      org_default = org_member
      org.update!(default_assignee: org_default)
      result = described_class.call(organization: org, reporter: reporter, params: params)
      expect(result.value.assignee).to eq(org_default)
    end

    it "l'ordine di fallback è progetto → team → org (il progetto vince)" do
      project_default = org_member
      team_default = org_member
      org_default = org_member
      project.update!(default_assignee: project_default)
      team = create(:team, organization: org, default_assignee: team_default)
      Connections::TeamProjectAccess.create!(team: team, project: project)
      org.update!(default_assignee: org_default)
      result = described_class.call(organization: org, reporter: reporter, params: params)
      expect(result.value.assignee).to eq(project_default)
    end

    it "il team vince sull'org quando il progetto non ha default" do
      team_default = org_member
      org_default = org_member
      team = create(:team, organization: org, default_assignee: team_default)
      Connections::TeamProjectAccess.create!(team: team, project: project)
      org.update!(default_assignee: org_default)
      result = described_class.call(organization: org, reporter: reporter, params: params)
      expect(result.value.assignee).to eq(team_default)
    end

    it "salta un default non più membro dell'org e ricade sul livello successivo" do
      ex_member = create(:account)
      membership = create(:membership, account: ex_member, organization: org)
      project.update!(default_assignee: ex_member) # valido: al momento del set è membro
      org_default = org_member
      org.update!(default_assignee: org_default)
      membership.destroy! # ex_member non è più membro dell'org

      result = described_class.call(organization: org, reporter: reporter, params: params)
      expect(result.value.assignee).to eq(org_default)
    end

    it "nessun default a nessun livello → ticket non assegnato" do
      result = described_class.call(organization: org, reporter: reporter, params: params)
      expect(result.value.assignee).to be_nil
    end

    it "un assignee_id esplicito ma non membro NON ricade sul default (anti-BOLA)" do
      project.update!(default_assignee: org_member)
      outsider = create(:account) # id esplicito ma non membro dell'org
      result = described_class.call(organization: org, reporter: reporter, params: params(assignee_id: outsider.id))
      expect(result).to be_ok
      expect(result.value.assignee).to be_nil # il default vale solo "in assenza" di assignee esplicito
    end

    it "un assignee_id esplicito inesistente NON ricade sul default" do
      project.update!(default_assignee: org_member)
      result = described_class.call(organization: org, reporter: reporter, params: params(assignee_id: SecureRandom.uuid))
      expect(result.value.assignee).to be_nil
    end
  end

  it "reporter god → apre ticket su qualsiasi progetto (unscoped, senza project membership)" do
    god = create(:account, god: true)
    create(:membership, account: god, organization: org, role: :member)
    result = described_class.call(organization: org, reporter: god, params: params)
    expect(result).to be_ok
    expect(result.value.reporter).to eq(god)
  end

  it "default kind = bug quando il chiamante non passa kind (es. PromoteToTicket)" do
    result = described_class.call(organization: org, reporter: reporter, params: params)
    expect(result.value).to be_kind_bug
  end

  it "crea una feature con la sola description (senza scenari)" do
    result = described_class.call(organization: org, reporter: reporter,
      params: params(kind: "story", description: "serve dark mode", scenarios_attributes: []))
    expect(result).to be_ok
    expect(result.value).to be_kind_story
    expect(result.value.description).to eq("serve dark mode")
  end

  it "crea una feature con la sola scenario (senza description) — il corpo vale per tutti i kind" do
    result = described_class.call(organization: org, reporter: reporter,
      params: params(kind: "story", description: "",
                     scenarios_attributes: [ { step_given: "sulla dashboard", step_when: "esporto" } ]))
    expect(result).to be_ok
    expect(result.value).to be_kind_story
  end

  it "feature senza corpo (né description né scenari) → R422-TICKET-001" do
    result = described_class.call(organization: org, reporter: reporter,
      params: params(kind: "story", description: "", scenarios_attributes: []))
    expect(result).to be_err
    expect(result.error.code).to eq("R422-TICKET-001")
  end

  it "assegna la milestone scoped all'org" do
    milestone = create(:milestone, project: project)
    result = described_class.call(organization: org, reporter: reporter, params: params(milestone_id: milestone.id))
    expect(result.value.milestone).to eq(milestone)
  end

  it "aggancia il ticket a un epic del progetto" do
    epic = create(:ticket, :epic, organization: org, project: project)
    result = described_class.call(organization: org, reporter: reporter, params: params(parent_id: epic.id))
    expect(result.value.parent).to eq(epic)
  end

  it "anti-BOLA: un epic di un ALTRO progetto non viene risolto (parent resta vuoto)" do
    foreign_epic = create(:ticket, :epic, organization: org, project: create(:project, organization: org))
    result = described_class.call(organization: org, reporter: reporter, params: params(parent_id: foreign_epic.id))
    expect(result).to be_ok
    expect(result.value.parent).to be_nil
  end

  it "parent_id di un ticket che non è un epic → 422" do
    story = create(:ticket, :story, organization: org, project: project)
    result = described_class.call(organization: org, reporter: reporter, params: params(parent_id: story.id))
    expect(result).to be_err
    expect(result.error.code).to eq("R422-TICKET-001")
  end

  it "assegna le piattaforme del progetto (platform_ids non vuoti → risolte scoped all'org)" do
    platform = create(:platform, organization: org)
    Connections::ProjectPlatform.create!(project: project, platform: platform)
    result = described_class.call(organization: org, reporter: reporter,
                                  params: params(platform_ids: [ "", platform.id ]))
    expect(result).to be_ok
    expect(result.value.platforms).to contain_exactly(platform)
  end

  describe "cronologia" do
    it "registra un evento `created` (attore = reporter, snapshot status/priority)" do
      result = nil
      expect do
        result = described_class.call(organization: org, reporter: reporter, params: params)
      end.to change(Ticketing::Event, :count).by(1)

      event = Ticketing::Event.last
      expect(event.ticket).to eq(result.value)
      expect(event.action).to eq("created")
      expect(event.actor).to eq(reporter)
      expect(event.data).to eq("status" => status.label, "priority" => priority.label)
    end

    it "registra true_actor in impersonation" do
      god = create(:account)
      described_class.call(organization: org, reporter: reporter, true_actor: god, params: params)
      expect(Ticketing::Event.last.true_actor).to eq(god)
    end

    it "create fallito (senza alcun corpo) → nessun evento" do
      expect do
        described_class.call(organization: org, reporter: reporter,
          params: params(scenarios_attributes: [], description: ""))
      end.not_to change(Ticketing::Event, :count)
    end

    it "rollback: evento invalido propaga e il ticket NON viene creato" do
      allow(Ticketing::RecordActivity).to receive(:call).and_raise(ActiveRecord::RecordInvalid)
      expect do
        expect do
          described_class.call(organization: org, reporter: reporter, params: params)
        end.to raise_error(ActiveRecord::RecordInvalid)
      end.not_to change(Ticketing::Ticket, :count)
    end
  end
  describe "embedding on-create" do
    it "accoda EmbedTicketJob per il ticket creato" do
      result = nil
      expect { result = described_class.call(organization: org, reporter: reporter, params: params) }
        .to have_enqueued_job(Ticketing::EmbedTicketJob).exactly(:once)
      expect(Ticketing::EmbedTicketJob).to have_been_enqueued.with(ticket_id: result.value.id)
    end
  end
end
