# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::RejectReview do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:in_review) { create(:ticket_status, :in_review, organization: org, position: 2) }
  let!(:in_progress) { create(:ticket_status, :in_progress, organization: org, position: 1) }
  let(:ticket) { create(:ticket, organization: org, project: project, status: in_review, with_agent_workflow: true) }
  let(:actor) { ticket.reporter }
  let(:reason) { "Manca il test sul caso limite" }

  def reject(**overrides)
    described_class.call(
      **{ organization: org, ticket: ticket, reason: reason, actor: actor }.merge(overrides)
    )
  end

  it "riporta il ticket sul primo status in_progress non review-gate (Result.ok)" do
    result = reject
    expect(result).to be_ok
    expect(ticket.reload.status).to eq(in_progress)
  end

  it "sceglie il target per position tra più candidati in_progress" do
    ahead = create(:ticket_status, :in_progress, organization: org, position: 0, label: "Doing")
    reject
    expect(ticket.reload.status).to eq(ahead)
  end

  it "ignora i candidati inattivi" do
    in_progress.update!(active: false)
    fallback = create(:ticket_status, :in_progress, organization: org, position: 5, label: "WIP")
    reject
    expect(ticket.reload.status).to eq(fallback)
  end

  it "registra un evento review_rejected con label prima→dopo e reason snapshottata" do
    expect { reject }.to change(Ticketing::Event, :count).by(1)

    event = Ticketing::Event.last
    expect(event.action).to eq("review_rejected")
    expect(event.actor).to eq(actor)
    # `mode` è nell'audit di proposito: "rifiutato" e "rifiutato rimandandolo all'agente" sono due
    # decisioni diverse, e a distanza di mesi la differenza non si ricostruisce da nient'altro.
    expect(event.data).to eq(
      "status" => { "from" => in_review.label, "to" => in_progress.label },
      "reason" => reason,
      "mode" => "hold"
    )
  end

  it "registra true_actor in impersonation" do
    god = create(:account)
    reject(true_actor: god)
    expect(Ticketing::Event.last.true_actor).to eq(god)
  end

  it "crea il commento col motivo a firma dell'attore" do
    expect { reject }.to change(Ticketing::Comment, :count).by(1)

    comment = Ticketing::Comment.last
    expect(comment.body).to eq(reason)
    expect(comment.author).to eq(actor)
    expect(comment.ticket).to eq(ticket)
  end

  it "accoda NotifyJob con l'evento e CommentNotifyJob per il commento" do
    expect { reject }.to have_enqueued_job(Ticketing::NotifyJob)
      .and have_enqueued_job(Ticketing::CommentNotifyJob)
  end

  # Il rifiuto umano su una lavorazione automatica ha due significati diversi, e prima ne aveva zero:
  # cambiava lo stato del ticket e non toccava il workflow, quindi la fase restava conclusa e non
  # approvata — né riproposta dalla coda né segnalata come ferma. Il ticket spariva, e l'unico modo di
  # farlo ripartire era uno sblocco a mano.
  describe "lavorazione automatica: i due modi di rifiutare" do
    let(:workflow) { ticket.agent_workflow }

    before do
      now = Time.current
      workflow.update!(triage_started_at: now, triaged_at: now, planned_at: now, approved_at: now,
                       autopilot_started_at: now, autopilot_completed_at: now)
    end

    it "rework: la fase torna in coda" do
      expect(workflow.ready_execution_phase).to be_nil

      expect(reject(mode: :rework)).to be_ok

      workflow.reload
      expect(workflow.autopilot_started_at).to be_nil
      expect(workflow.autopilot_completed_at).to be_nil
      expect(workflow.ready_execution_phase).to eq("autopilot")
    end

    it "rework: il budget di revisione riparte, così i tentativi dichiarati sono davvero due" do
      workflow.update!(blocked_at: Time.current, blocked_phase: "autopilot", blocked_kind: "attempt_limit", blocked_reason: "review_limit")

      expect(reject(mode: :rework)).to be_ok

      workflow.reload
      expect(workflow.blocked_at).to be_nil
      expect(workflow.blocked_phase).to be_nil
      expect(workflow.review_budget_from).to be_present
    end

    it "hold: il ticket torna in lavorazione ma nessuno lo ripropone alle macchine" do
      expect(reject(mode: :hold)).to be_ok

      workflow.reload
      expect(workflow.autopilot_completed_at).to be_present
      expect(workflow.ready_execution_phase).to be_nil
    end

    # Il default protegge i canali che non conoscono ancora la scelta (CLI, integrazioni): mai una
    # ripartenza che nessuno ha chiesto.
    it "senza mode si comporta come hold" do
      expect(reject).to be_ok
      expect(workflow.reload.ready_execution_phase).to be_nil
    end

    it "un mode sconosciuto non fa ripartire niente" do
      expect(reject(mode: "riprova-tutto")).to be_ok
      expect(workflow.reload.ready_execution_phase).to be_nil
    end

    it "non tocca un workflow annullato o completato" do
      workflow.update!(cancelled_at: Time.current)

      expect(reject(mode: :rework)).to be_ok
      expect(workflow.reload.autopilot_completed_at).to be_present
    end
  end

  it "su un ticket senza lavorazione automatica il rifiuto resta quello di prima" do
    plain = create(:ticket, organization: org, project: project, status: in_review)

    result = described_class.call(organization: org, ticket: plain, reason: reason, actor: actor,
                                  mode: :rework)

    expect(result).to be_ok
    expect(plain.reload.status).to eq(in_progress)
    expect(plain.agent_workflow).to be_nil
  end

  describe "guard" do
    it "ticket non in review → err R422-TICKET-006, nessuna mutazione" do
      ticket.update!(status: in_progress)
      expect { @result = reject }.to not_change(Ticketing::Event, :count)
        .and not_change(Ticketing::Comment, :count)
      expect(@result).to be_err
      expect(@result.error.code).to eq("R422-TICKET-006")
      expect(ticket.reload.status).to eq(in_progress)
    end

    it "reason blank → err R422-TICKET-007, nessuna mutazione" do
      [ nil, "", "   " ].each do |blank|
        result = reject(reason: blank)
        expect(result).to be_err
        expect(result.error.code).to eq("R422-TICKET-007")
      end
      expect(ticket.reload.status).to eq(in_review)
      expect(Ticketing::Comment.count).to eq(0)
    end

    it "nessun candidato in_progress non-gate → err R422-TICKET-008" do
      in_progress.destroy!
      result = reject
      expect(result).to be_err
      expect(result.error.code).to eq("R422-TICKET-008")
      expect(ticket.reload.status).to eq(in_review)
    end

    # CYRA-389 — la motivazione non è più tenuta dentro il tetto del commento, ma un tetto ce l'ha
    # (quello del resoconto, che è il posto in cui finisce): serve a fermare chi ci scarichi un diff
    # intero, non chi scrive una motivazione. Il guard sta PRIMA della transazione: chi supera il
    # tetto riceve un errore col testo ancora in mano, invece di un respingimento a metà.
    it "motivazione oltre il tetto del resoconto → err R422-TICKET-018, nessuna mutazione" do
      result = reject(reason: "x" * (Ticketing::Constants::REVIEW_REASON_MAX_CHARS + 1))

      expect(result).to be_err
      expect(result.error.code).to eq("R422-TICKET-018")
      expect(ticket.reload.status).to eq(in_review)
      expect(Ticketing::Comment.count).to eq(0)
      expect(Ticketing::Report.count).to eq(0)
    end
  end

  # CYRA-389 — chi respinge un lavoro consegnato scrive la cosa più importante del gesto, e il tetto
  # del commento (240 caratteri) è la misura di un messaggio breve, non di una motivazione. Prima di
  # questo blocco una motivazione lunga finiva in un warn nei log: restava solo nel jsonb dell'evento,
  # che nessuna pagina mostra, quindi il perché del respingimento usciva dal prodotto.
  describe "dove finisce la motivazione" do
    # 25 caratteri × 20 = 500, ben oltre il tetto del commento e ben sotto quello del resoconto.
    let(:long_reason) { "Il caso limite non va. " * 25 }

    it "una motivazione breve resta un commento in discussione, come prima" do
      expect { reject }.to change(Ticketing::Comment, :count).by(1)
        .and not_change(Ticketing::Report, :count)

      expect(Ticketing::Comment.last.body).to eq(reason)
    end

    it "una motivazione lunga diventa una versione del resoconto, per intero" do
      expect { reject(reason: long_reason) }.to change(Ticketing::Report, :count).by(1)

      report = ticket.reload.current_report
      expect(report.body).to eq(long_reason.strip)
      expect(report).to be_source_review_rejection
      expect(report.author).to eq(actor)
    end

    # In discussione non resta il vuoto: la riga di servizio dice che il resoconto è cambiato, che è
    # il rimando al posto dove leggere. È la stessa riga che il prodotto scrive già per un resoconto
    # nuovo, quindi non c'è un secondo posto da imparare.
    it "in discussione resta la riga di servizio che rimanda al resoconto" do
      expect { reject(reason: long_reason) }.to change(Ticketing::Comment, :count).by(1)

      comment = Ticketing::Comment.last
      expect(comment.body).to eq(I18n.t("ticketing.reports.service_line.review_rejection"))
      expect(comment.body.length).to be <= Ticketing::Constants::COMMENT_MAX_CHARS
      expect(comment).to be_kind_service
    end

    it "la motivazione lunga resta anche nell'evento, per l'audit" do
      reject(reason: long_reason)

      expect(Ticketing::Event.last.data["reason"]).to eq(long_reason.strip)
    end

    # Stesso patto del commento non creabile: il respingimento è già committato e la motivazione è
    # nell'evento — un resoconto non scrivibile non lo annulla.
    it "il respingimento sopravvive a un resoconto non scrivibile" do
      allow(Ticketing::RecordReport).to receive(:call)
        .and_return(Result.err(AppError.new("boom", code: "R422-REPORT-001")))

      result = reject(reason: long_reason)

      expect(result).to be_ok
      expect(ticket.reload.status).to eq(in_progress)
      expect(Ticketing::Event.last.data["reason"]).to eq(long_reason.strip)
    end
  end

  it "rollback atomico: se l'evento fallisce, status invariato e nessun commento" do
    allow(Ticketing::RecordActivity).to receive(:call).and_raise(ActiveRecord::RecordInvalid)
    expect { reject }.to raise_error(ActiveRecord::RecordInvalid)
    expect(ticket.reload.status).to eq(in_review)
    expect(Ticketing::Comment.count).to eq(0)
  end

  it "il rifiuto sopravvive a un commento non creabile (reason già nell'evento)" do
    allow(Ticketing::AddComment).to receive(:call)
      .and_return(Result.err(AppError.new("boom", code: "R422-COMMENT-001")))
    result = reject
    expect(result).to be_ok
    expect(ticket.reload.status).to eq(in_progress)
    expect(Ticketing::Event.last.data["reason"]).to eq(reason)
  end

  describe "broadcast realtime (post-commit)" do
    let(:board_stream) { Realtime::Streams.project_board(ticket.project) }
    let(:card_id) { "ticketing_ticket_#{ticket.id}" }

    it "manda un refresh sulla board del progetto, senza HTML della card (CYRA-257)" do
      seen = []
      expect { reject }.to have_broadcasted_to(board_stream).exactly(:once).with { |html| seen << html }

      expect(seen.first).to include(%(action="refresh"))
      expect(seen.first).not_to include(card_id, ticket.title)
    end

    it "guard fallito → nessun broadcast" do
      ticket.update!(status: in_progress)
      expect { reject }.not_to have_broadcasted_to(board_stream)
    end
  end
end
