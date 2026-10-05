# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::UpdateTicket do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:status) { create(:ticket_status, organization: org) }
  let(:priority) { create(:ticket_priority, organization: org) }
  let(:ticket) { create(:ticket, organization: org, project: project, status: status, priority: priority, title: "Old", with_agent_workflow: true) }

  # Corpo NON toccato di default: il ticket del factory ha già uno scenario → resta valido.
  def params(extra = {})
    { title: "New", status_id: status.id, priority_id: priority.id }.merge(extra)
  end

  it "aggiorna il ticket (Result.ok)" do
    result = described_class.call(channel: :web, organization: org, ticket: ticket, params: params)
    expect(result).to be_ok
    expect(ticket.reload.title).to eq("New")
  end

  it "blocca il corpo dopo il claim triage ma lascia aggiornare i meta" do
    ticket.agent_workflow.update!(triage_started_at: Time.current)

    blocked = described_class.call(channel: :web, organization: org, ticket:, params: params(title: "Bloccato"))
    expect(blocked).to be_err
    expect(blocked.error.code).to eq("R409-TICKET-006")
    expect(ticket.reload.title).to eq("Old")

    allowed = described_class.call(channel: :web,
      organization: org, ticket:,
      params: { status_id: status.id, priority_id: priority.id, weight: 3 }
    )
    expect(allowed).to be_ok
    expect(ticket.reload.weight).to eq(3)
  end

  # Il browser rimanda le textarea con fine-riga CRLF, il DB tiene LF: un corpo RINVIATO IDENTICO
  # non deve contare come modifica, altrimenti a corpo bloccato un salvataggio innocuo dà R409.
  it "a corpo bloccato non conta come modifica una descrizione identica rimandata con CRLF" do
    ticket.update!(description: "Prima riga\nSeconda riga")
    ticket.agent_workflow.update!(triage_started_at: Time.current)

    result = described_class.call(channel: :web,
      organization: org, ticket:,
      params: { status_id: status.id, priority_id: priority.id, weight: 5,
                description: "Prima riga\r\nSeconda riga" }
    )

    expect(result).to be_ok
    expect(ticket.reload.weight).to eq(5)
    expect(ticket.description).to eq("Prima riga\nSeconda riga")
  end

  # Ticket scritto prima della normalizzazione: in DB il corpo ha ancora i CRLF (Rails normalizza
  # in scrittura, non in lettura). Anche il valore CORRENTE va normalizzato per il confronto,
  # altrimenti a corpo bloccato un salvataggio che non tocca nulla verrebbe rifiutato.
  it "a corpo bloccato non conta come modifica un corpo legacy con CRLF rimandato identico" do
    grezzo = "Prima riga\r\nSeconda riga"
    Ticketing::Ticket.connection.update(
      Ticketing::Ticket.sanitize_sql_array(
        [ "UPDATE ticketing_tickets SET description = ? WHERE id = ?", grezzo, ticket.id ]
      )
    )
    ticket.reload
    ticket.agent_workflow.update!(triage_started_at: Time.current)

    result = described_class.call(channel: :web,
      organization: org, ticket:,
      params: { status_id: status.id, priority_id: priority.id, weight: 7, description: grezzo }
    )

    expect(result).to be_ok
    expect(ticket.reload.weight).to eq(7)
  end

  it "titolo vuoto → Result.err R422-TICKET-002, ticket invariato" do
    result = described_class.call(channel: :web, organization: org, ticket: ticket, params: params(title: ""))
    expect(result).to be_err
    expect(result.error.code).to eq("R422-TICKET-002")
    expect(ticket.reload.title).to eq("Old")
  end

  it "assegna un membro" do
    member = create(:account)
    create(:membership, account: member, organization: org, role: :member)
    described_class.call(channel: :web, organization: org, ticket: ticket, params: params(assignee_id: member.id))
    expect(ticket.reload.assignee).to eq(member)
  end

  it "assegna/cambia la milestone (scoped all'org)" do
    milestone = create(:milestone, project: project)
    described_class.call(channel: :web, organization: org, ticket: ticket, params: params(milestone_id: milestone.id))
    expect(ticket.reload.milestone).to eq(milestone)
  end

  it "aggancia e stacca l'epic padre, registrando il diff col codice dell'epic" do
    epic = create(:ticket, :epic, organization: org, project: project)

    # Gli id degli eventi sono UUID: `.last` su una relation non ordinata non è l'ultimo evento.
    # Ogni passo confronta quindi l'evento NUOVO rispetto a quelli già presenti.
    seen = Ticketing::Event.pluck(:id)
    described_class.call(channel: :web, organization: org, ticket: ticket, params: params(parent_id: epic.id))
    expect(ticket.reload.parent).to eq(epic)
    attached = Ticketing::Event.where.not(id: seen).sole
    expect(attached.data["parent"]).to eq("from" => nil, "to" => epic.code)

    seen = Ticketing::Event.pluck(:id)
    described_class.call(channel: :web, organization: org, ticket: ticket, params: params(parent_id: ""))
    expect(ticket.reload.parent).to be_nil
    detached = Ticketing::Event.where.not(id: seen).sole
    expect(detached.data["parent"]).to eq("from" => epic.code, "to" => nil)
  end

  it "converte un bug in story (kind + description); il corpo esistente resta valido" do
    result = described_class.call(channel: :web, organization: org, ticket: ticket,
      params: params(kind: "story", description: "ridisegno checkout"))
    expect(result).to be_ok
    expect(ticket.reload).to be_kind_story
    expect(ticket.description).to eq("ridisegno checkout")
  end

  it "aggiorna scenari, DoD e analisi tecnica via nested attributes" do
    result = described_class.call(channel: :web, organization: org, ticket: ticket, params: params(
      scenarios_attributes: [ { title: "Nuovo", step_given: "x", step_when: "y", step_then: "z" } ],
      conditions_attributes: [ { text: "criterio verificabile" } ],
      technical_analysis: "N+1 su Orders#index",
    ))
    expect(result).to be_ok
    ticket.reload
    expect(ticket.scenarios.map(&:title)).to eq([ "Nuovo" ])
    expect(ticket.conditions.map(&:text)).to eq([ "criterio verificabile" ])
    expect(ticket.technical_analysis).to eq("N+1 su Orders#index")
  end

  it "sostituisce gli scenari esistenti invece di accumularli (nessun id = canale CLI)" do
    t = create(:ticket, :with_scenarios, organization: org, project: project,
               status: status, priority: priority, scenarios_count: 2)
    described_class.call(channel: :web, organization: org, ticket: t, params: params(
      scenarios_attributes: [ { title: "Solo", step_given: "g" } ]
    ))
    expect(t.reload.scenarios.map(&:title)).to eq([ "Solo" ])
  end

  it "sostituisce le condizioni (DoD) esistenti invece di accumularle" do
    t = create(:ticket, :with_conditions, organization: org, project: project,
               status: status, priority: priority, conditions_count: 2)
    described_class.call(channel: :web, organization: org, ticket: t, params: params(
      conditions_attributes: [ { text: "unica" } ]
    ))
    expect(t.reload.conditions.map(&:text)).to eq([ "unica" ])
  end

  it "canale web: tiene le righe con id, aggiunge le nuove, elimina le omesse" do
    t = create(:ticket, :with_scenarios, organization: org, project: project,
               status: status, priority: priority, scenarios_count: 2)
    keep, drop = t.scenarios.to_a
    described_class.call(channel: :web, organization: org, ticket: t, params: params(
      scenarios_attributes: [ { id: keep.id, step_given: "aggiornato" }, { step_given: "nuovo" } ]
    ))
    t.reload
    expect(t.scenarios.pluck(:id)).to include(keep.id)
    expect(t.scenarios.pluck(:id)).not_to include(drop.id)
    expect(t.scenarios.count).to eq(2)
    expect(keep.reload.step_given).to eq("aggiornato")
  end

  it "canale web con nested indicizzato Hash {\"0\"=>…,\"1\"=>…}: sostituisce senza esplodere (CYRA-171 regressione)" do
    # Il form web invia i nested attributes come Hash INDICIZZATO, non come Array — iterarlo con
    # filter_map darebbe coppie [k,v] e row[:id] esploderebbe (bug scoperto dai system spec).
    t = create(:ticket, :with_scenarios, organization: org, project: project,
               status: status, priority: priority, scenarios_count: 2)
    keep, drop = t.scenarios.to_a
    result = described_class.call(channel: :web, organization: org, ticket: t, params: params(
      scenarios_attributes: { "0" => { id: keep.id, step_given: "aggiornato" }, "1" => { step_given: "nuovo" } }
    ))
    expect(result).to be_ok
    t.reload
    expect(t.scenarios.pluck(:id)).to include(keep.id)
    expect(t.scenarios.pluck(:id)).not_to include(drop.id)
    expect(t.scenarios.count).to eq(2)
    expect(keep.reload.step_given).to eq("aggiornato")
  end

  it "registra scenari/DoD/analisi tecnica cambiati nella cronologia" do
    described_class.call(channel: :web, organization: org, ticket: ticket, actor: ticket.reporter, params: params(
      scenarios_attributes: [ { step_given: "nuovo contesto" } ],
      conditions_attributes: [ { text: "criterio" } ],
      technical_analysis: "stack qui",
    ))
    data = ticket.events.where(action: "updated").last.data
    expect(data).to have_key("scenarios")
    expect(data).to have_key("conditions")
    expect(data["technical_analysis"]).to eq([ nil, "stack qui" ])
  end

  it "registra il cambio kind nella cronologia (chiavi umane bug→story)" do
    described_class.call(channel: :web, organization: org, ticket: ticket, params: params(kind: "story", description: "x"))
    event = ticket.events.where(action: "updated").last
    expect(event.data["kind"]).to eq({ "from" => "bug", "to" => "story" })
  end

  describe "cronologia" do
    let(:actor) { ticket.reporter }

    # CYRA-244: lo status non è più aggregato nell'evento `updated` — è delegato a ChangeStatus, che
    # emette il proprio `status_changed` tipizzato (con notifica e broadcast). Il resto (title) resta
    # nell'evento `updated`, senza la chiave status (niente doppia riga in cronologia).
    it "il cambio di stato esce come `status_changed`, il resto resta in `updated`" do
      new_status = create(:ticket_status, organization: org, label: "Chiuso")
      seen = Ticketing::Event.pluck(:id)

      described_class.call(channel: :web, organization: org, ticket: ticket,
                           params: params(title: "Nuovo", status_id: new_status.id), actor: actor)

      events = Ticketing::Event.where.not(id: seen)
      status_event = events.find_by(action: "status_changed")
      expect(status_event.data["status"]).to eq("from" => status.label, "to" => "Chiuso")
      updated_event = events.find_by(action: "updated")
      expect(updated_event.data["title"]).to eq([ "Old", "Nuovo" ])
      expect(updated_event.data).not_to have_key("status")
    end

    it "no-op (richiamo con gli stessi valori) → nessun nuovo evento" do
      described_class.call(channel: :web, organization: org, ticket: ticket, params: params, actor: actor)
      ticket.reload
      expect do
        described_class.call(channel: :web, organization: org, ticket: ticket, params: params, actor: actor)
      end.not_to change(Ticketing::Event, :count)
    end

    it "save fallito → nessun evento" do
      expect do
        described_class.call(channel: :web, organization: org, ticket: ticket, params: params(title: ""), actor: actor)
      end.not_to change(Ticketing::Event, :count)
    end

    it "rollback: evento invalido propaga e il ticket resta invariato" do
      allow(Ticketing::RecordActivity).to receive(:call).and_raise(ActiveRecord::RecordInvalid)
      expect do
        described_class.call(channel: :web, organization: org, ticket: ticket, params: params(title: "Nuovo"), actor: actor)
      end.to raise_error(ActiveRecord::RecordInvalid)
      expect(ticket.reload.title).to eq("Old")
    end

    it "registra il cambio di priorità (label prima→dopo)" do
      new_priority = create(:ticket_priority, organization: org, label: "Alta")
      described_class.call(channel: :web, organization: org, ticket: ticket,
                           params: params(priority_id: new_priority.id), actor: actor)

      expect(Ticketing::Event.last.data["priority"]).to eq("from" => priority.label, "to" => "Alta")
    end

    it "registra le piattaforme aggiunte (0→1)" do
      platform = create(:platform, organization: org, label: "iOS")
      Connections::ProjectPlatform.create!(project: project, platform: platform)

      described_class.call(channel: :web, organization: org, ticket: ticket,
                           params: params(platform_ids: [ platform.id ]), actor: actor)

      expect(Ticketing::Event.last.data["platforms"]).to eq("added" => [ "iOS" ], "removed" => [])
    end

    it "registra le piattaforme rimosse (1→0)" do
      platform = create(:platform, organization: org, label: "iOS")
      Connections::ProjectPlatform.create!(project: project, platform: platform)
      ticket.update!(platforms: [ platform ])

      described_class.call(channel: :web, organization: org, ticket: ticket,
                           params: params(platform_ids: []), actor: actor)

      expect(Ticketing::Event.last.data["platforms"]).to eq("added" => [], "removed" => [ "iOS" ])
    end

    it "cambio di SOLE piattaforme → l'evento `updated` ha solo la chiave platforms" do
      platform = create(:platform, organization: org, label: "iOS")
      Connections::ProjectPlatform.create!(project: project, platform: platform)
      # primo update allinea il ticket ai params base (title/step/status/priority) → settled
      described_class.call(channel: :web, organization: org, ticket: ticket, params: params, actor: actor)
      ticket.reload
      seen = Ticketing::Event.pluck(:id)

      described_class.call(channel: :web, organization: org, ticket: ticket,
                           params: params(platform_ids: [ platform.id ]), actor: actor)

      # isolo l'evento NUOVO via delta (Event.last è ambiguo: PK UUID, non insertion order)
      new_event = Ticketing::Event.where.not(id: seen).sole
      expect(new_event.data.keys).to eq([ "platforms" ])
    end

    # CYRA-244: la rimozione dell'assegnatario è delegata ad AssignTicket → evento `unassigned`
    # tipizzato (non più aggregato in `updated`).
    it "rimuove l'assegnatario via AssignTicket e registra `unassigned` (nome prima → nil dopo)" do
      assignee = create(:account)
      create(:membership, account: assignee, organization: org, role: :member)
      ticket.update!(assignee: assignee)
      ticket.reload
      seen = Ticketing::Event.pluck(:id)

      described_class.call(channel: :web, organization: org, ticket: ticket, params: params, actor: actor)

      expect(ticket.reload.assignee).to be_nil
      event = Ticketing::Event.where.not(id: seen).find_by(action: "unassigned")
      expect(event.data["assignee"]).to eq("from" => assignee.name, "to" => nil)
    end

    # CYRA-244: la rimozione della milestone è delegata a ChangeMilestone → evento `milestone_changed`.
    it "rimuove la milestone via ChangeMilestone e registra `milestone_changed` (label prima → nil)" do
      milestone = create(:milestone, project: project)
      ticket.update!(milestone: milestone)
      ticket.reload
      seen = Ticketing::Event.pluck(:id)

      described_class.call(channel: :web, organization: org, ticket: ticket, params: params, actor: actor)

      expect(ticket.reload.milestone).to be_nil
      event = Ticketing::Event.where.not(id: seen).find_by(action: "milestone_changed")
      expect(event.data["milestone"]).to eq("from" => milestone.label, "to" => nil)
    end
  end
  describe "embedding on-update" do
    it "accoda il re-embed quando cambia il testo semantico (title)" do
      expect { described_class.call(channel: :web, organization: org, ticket: ticket, params: params) }
        .to have_enqueued_job(Ticketing::EmbedTicketJob).with(ticket_id: ticket.id)
    end

    it "accoda il re-embed quando cambiano gli scenari (record a parte, non in saved_changes)" do
      expect do
        described_class.call(channel: :web, organization: org, ticket: ticket,
                             params: params(title: ticket.title,
                                            scenarios_attributes: [ { step_given: "step nuovo" } ]))
      end.to have_enqueued_job(Ticketing::EmbedTicketJob).with(ticket_id: ticket.id)
    end

    it "NON accoda il re-embed su un cambio di solo status (nessun testo semantico cambiato)" do
      other_status = create(:ticket_status, organization: org)
      # Corpo NON toccato (niente scenarios_attributes) + title invariato → solo status cambia.
      same_text = { title: ticket.title, status_id: other_status.id, priority_id: priority.id }

      expect { described_class.call(channel: :web, organization: org, ticket: ticket, params: same_text) }
        .not_to have_enqueued_job(Ticketing::EmbedTicketJob)
    end
  end

  # CYRA-244: salvando dal modulo di modifica, stato/responsabile/traguardo devono produrre gli
  # stessi effetti dei pulsanti rapidi — evento tipizzato, notifica ai watcher, auto-iscrizione
  # dell'assegnatario, ping al revisore — che l'aggregazione in `updated` non produceva.
  describe "delega di stato/responsabile/traguardo ai service dedicati (CYRA-244)" do
    include ActiveJob::TestHelper

    let(:actor) do
      create(:account).tap { |a| create(:membership, account: a, organization: org, role: :member) }
    end
    let(:member) do
      create(:account).tap { |a| create(:membership, account: a, organization: org, role: :member) }
    end

    it "cambiando stato accoda la notifica ai watcher (come i pulsanti rapidi)" do
      new_status = create(:ticket_status, organization: org)

      expect do
        described_class.call(channel: :web, organization: org, ticket: ticket, actor: actor,
                             params: params(status_id: new_status.id))
      end.to have_enqueued_job(Ticketing::NotifyJob)

      expect(ticket.reload.status).to eq(new_status)
    end

    it "assegnando un membro: evento `assigned`, notifica e il membro inizia a seguire il ticket" do
      expect do
        perform_enqueued_jobs(only: Ticketing::NotifyJob) do
          described_class.call(channel: :web, organization: org, ticket: ticket, actor: actor,
                               params: params(assignee_id: member.id))
        end
      end.to change { ticket.subscriptions.where(account: member).count }.from(0).to(1)

      expect(ticket.reload.assignee).to eq(member)
      expect(Ticketing::Event.where(ticket: ticket, action: "assigned")).to exist
      expect(Alerting::Notification.where(account: member, event_type: :ticket_assigned)).to exist
    end

    it "cambiando traguardo accoda la notifica ai watcher" do
      milestone = create(:milestone, project: project)

      expect do
        described_class.call(channel: :web, organization: org, ticket: ticket, actor: actor,
                             params: params(milestone_id: milestone.id))
      end.to have_enqueued_job(Ticketing::NotifyJob)

      expect(ticket.reload.milestone).to eq(milestone)
    end

    it "portando il ticket in uno stato di revisione avvisa il revisore" do
      reviewer = create(:account).tap { |a| create(:membership, account: a, organization: org, role: :member) }
      ticket.update!(reviewer: reviewer)
      review_status = create(:ticket_status, :in_review, organization: org)

      perform_enqueued_jobs(only: Ticketing::NotifyJob) do
        described_class.call(channel: :web, organization: org, ticket: ticket, actor: actor,
                             params: params(status_id: review_status.id))
      end

      expect(Alerting::Notification.where(account: reviewer, event_type: :ticket_review_requested)).to exist
    end

    it "un salvataggio che non tocca stato/responsabile/traguardo non accoda NotifyJob" do
      expect do
        described_class.call(channel: :web, organization: org, ticket: ticket, actor: actor,
                             params: params(description: "solo corpo"))
      end.not_to have_enqueued_job(Ticketing::NotifyJob)
    end

    # Regressione: la delega ai service avviene DOPO il salvataggio del corpo. Se il corpo è invalido
    # l'update esce con 422 senza aver cambiato lo stato né accodato notifiche — nessun side effect
    # spurio per un salvataggio che poi fallisce.
    it "corpo invalido → 422 senza cambiare stato né far partire notifiche" do
      new_status = create(:ticket_status, organization: org)

      expect do
        result = described_class.call(channel: :web, organization: org, ticket: ticket, actor: actor,
                                      params: params(title: "", status_id: new_status.id))
        expect(result).to be_err
        expect(result.error.code).to eq("R422-TICKET-002")
      end.not_to have_enqueued_job(Ticketing::NotifyJob)

      expect(ticket.reload.status).to eq(status)
      expect(ticket.title).to eq("Old")
    end
  end

  # CYRA-788 — un salvataggio è UNA mossa: se un campo viene rifiutato, il ticket resta com'era per intero.
  # Prima corpo ed evento `updated` erano già committati quando lo stato o il traguardo dicevano di no.
  describe "atomicità del salvataggio (CYRA-788)" do
    include ActiveJob::TestHelper

    let(:actor) do
      create(:account).tap { |a| create(:membership, account: a, organization: org, role: :member) }
    end
    let(:member) do
      create(:account).tap { |a| create(:membership, account: a, organization: org, role: :member) }
    end
    let(:in_progress) { create(:ticket_status, :in_progress, organization: org) }

    def blocca_con_prerequisito_aperto(ticket)
      blocker = create(:ticket, organization: org, project: project, status: status)
      create(:ticket_dependency, ticket: ticket, blocker: blocker)
    end

    it "stato rifiutato (prerequisito aperto) → titolo non salvato, nessun evento, nessun job" do
      blocca_con_prerequisito_aperto(ticket)

      expect do
        result = described_class.call(channel: :web, organization: org, ticket: ticket, actor: actor,
                                      params: params(title: "Nuovo titolo", status_id: in_progress.id))
        expect(result).to be_err
        expect(result.error.code).to eq("R422-TICKET-014")
      end.not_to have_enqueued_job

      expect(ticket.reload.title).to eq("Old")
      expect(ticket.status).to eq(status)
      expect(Ticketing::Event.where(ticket: ticket)).not_to exist
    end

    it "traguardo rifiutato → anche stato e assegnatario già passati non risultano salvati" do
      milestone_altrui = create(:milestone, project: create(:project, organization: org))
      new_status = create(:ticket_status, organization: org)

      expect do
        result = described_class.call(channel: :web, organization: org, ticket: ticket, actor: actor,
                                      params: params(title: "Nuovo titolo", status_id: new_status.id,
                                                     assignee_id: member.id, milestone_id: milestone_altrui.id))
        expect(result).to be_err
        expect(result.error.code).to eq("R422-TICKET-004")
      end.not_to have_enqueued_job

      ticket.reload
      expect(ticket.title).to eq("Old")
      expect(ticket.status).to eq(status)
      expect(ticket.assignee).to be_nil
      expect(ticket.milestone).to be_nil
      expect(Ticketing::Event.where(ticket: ticket)).not_to exist
      expect(ticket.subscriptions.where(account: member)).not_to exist
    end

    it "salvataggio riuscito → titolo, stato, assegnatario e traguardo salvati con eventi e notifiche" do
      milestone = create(:milestone, project: project)
      new_status = create(:ticket_status, organization: org)

      expect do
        result = described_class.call(channel: :web, organization: org, ticket: ticket, actor: actor,
                                      params: params(title: "Nuovo titolo", status_id: new_status.id,
                                                     assignee_id: member.id, milestone_id: milestone.id))
        expect(result).to be_ok
      end.to have_enqueued_job(Ticketing::NotifyJob).exactly(3).times
         .and have_enqueued_job(Ticketing::EmbedTicketJob).once

      ticket.reload
      expect(ticket.title).to eq("Nuovo titolo")
      expect(ticket.status).to eq(new_status)
      expect(ticket.assignee).to eq(member)
      expect(ticket.milestone).to eq(milestone)
      expect(Ticketing::Event.where(ticket: ticket).pluck(:action))
        .to contain_exactly("updated", "status_changed", "assigned", "milestone_changed")
    end
  end
end
