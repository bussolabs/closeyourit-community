# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::Notifications::DispatchEvent do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization: organization) }
  let(:actor) do
    create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :member) }
  end
  let(:watcher) do
    create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :member) }
  end
  let(:ticket) { create(:ticket, organization: organization, project: project, reporter: actor) }

  def dispatch(event, at: Time.current)
    described_class.call(event: event, at: at)
  end

  describe "evento status_changed (destinatari = watcher)" do
    let(:event) do
      create(:ticket_event, ticket: ticket, actor: actor, action: "status_changed",
                            data: { "status" => { "from" => "Open", "to" => "In progress" } })
    end

    before { Ticketing::Subscription.ensure_for(ticket: ticket, account: watcher, source: :manual) }

    it "notifica i watcher e ESCLUDE l'attore" do
      dispatch(event)
      expect(Alerting::Notification.where(account: watcher, via: :in_app, event_type: :ticket_status_changed)).to exist
      expect(Alerting::Notification.where(account: actor)).not_to exist
    end

    it "cadenza email off per l'evento → nessuna email, ma l'in-app resta" do
      create(:alerting_preference, account: watcher, organization: organization,
                                   email_cadences: { "ticket_status_changed" => "off" })
      dispatch(event)
      expect(Alerting::Notification.where(account: watcher, via: :in_app)).to exist
      expect(Alerting::Notification.where(account: watcher, via: :email)).not_to exist
    end

    it "email_enabled = false → solo in-app" do
      create(:alerting_preference, account: watcher, organization: organization, email_enabled: false)
      dispatch(event)
      expect(Alerting::Notification.where(account: watcher, via: :in_app)).to exist
      expect(Alerting::Notification.where(account: watcher, via: :email)).not_to exist
    end

    it "in-app sempre attiva anche col vecchio flag in_app_enabled = false" do
      create(:alerting_preference, account: watcher, organization: organization, in_app_enabled: false)
      dispatch(event)
      expect(Alerting::Notification.where(account: watcher, via: :in_app)).to exist
    end

    it "telegram acceso + account collegato → invia il DM e crea la riga via telegram" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("TELEGRAM_BOT_TOKEN").and_return("999:xyz")
      stub = stub_request(:post, "https://api.telegram.org/bot999:xyz/sendMessage").to_return(status: 200)
      watcher.update!(telegram_chat_id: "800")
      create(:alerting_preference, account: watcher, organization: organization, telegram_enabled: true)

      dispatch(event)

      expect(stub).to have_been_requested
      expect(Alerting::Notification.where(account: watcher, via: :telegram)).to exist
    end

    it "esclude l'attore anche quando è iscritto al ticket" do
      Ticketing::Subscription.ensure_for(ticket: ticket, account: actor, source: :manual)
      dispatch(event)
      expect(Alerting::Notification.where(account: actor)).not_to exist
    end

    it "quiet hours → email trattenuta (:held), in-app comunque sent" do
      create(:alerting_preference, :quiet_nights, account: watcher, organization: organization)
      dispatch(event, at: Time.utc(2026, 1, 15, 22, 0)) # Rome 23:00 → quiet
      expect(Alerting::Notification.where(account: watcher, via: :in_app, status: :sent)).to exist
      expect(Alerting::Notification.where(account: watcher, via: :email, status: :held)).to exist
    end

    it "accoda la mail di notifica quando l'email è attiva" do
      expect { dispatch(event) }.to have_enqueued_mail(Ticketing::TicketNotificationsMailer, :notify)
    end

    it "re-dispatch dello stesso evento → nessun duplicato (idempotenza)" do
      dispatch(event)
      expect { dispatch(event) }.not_to change(Alerting::Notification, :count)
    end

    it "azione non notificabile → no-op (guard ACTION_EVENT_TYPES)" do
      other = create(:ticket_event, ticket: ticket, actor: actor, action: "attached", data: {})
      expect { dispatch(other) }.not_to change(Alerting::Notification, :count)
    end
  end

  describe "evento created (destinatario = solo l'assegnatario, se diverso dal reporter)" do
    let!(:owner) do
      create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :owner) }
    end
    let(:assignee) do
      create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :member) }
    end
    let(:event) do
      create(:ticket_event, ticket: ticket, actor: actor, action: "created",
                            data: { "status" => "Open", "priority" => "Low" })
    end

    it "notifica SOLO l'assegnatario, non il reporter né altri membri del team" do
      ticket.update!(assignee: assignee)
      dispatch(event)
      expect(Alerting::Notification.where(account: assignee, via: :in_app, event_type: :ticket_created)).to exist
      expect(Alerting::Notification.where(account: actor)).not_to exist # reporter/attore
      expect(Alerting::Notification.where(account: owner)).not_to exist # membro non assegnatario
    end

    it "assegnatario == reporter → nessuna notifica di creazione" do
      ticket.update!(assignee: actor)
      expect { dispatch(event) }.not_to change(Alerting::Notification, :count)
    end

    it "senza assegnatario → nessuna notifica di creazione" do
      expect { dispatch(event) }.not_to change(Alerting::Notification, :count)
    end

    it "auto-iscrive il reporter (per gli eventi futuri)" do
      expect { dispatch(event) }.to change { ticket.subscriptions.where(account: actor).count }.by(1)
    end

    it "auto-iscrive l'assegnatario impostato a creazione" do
      ticket.update!(assignee: assignee)
      expect { dispatch(event) }.to change { ticket.subscriptions.where(account: assignee, source: :assignee).count }.by(1)
    end
  end

  describe "evento assigned" do
    let(:assignee) do
      create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :member) }
    end

    it "auto-iscrive e notifica l'assegnatario (diverso dall'attore)" do
      ticket.update!(assignee: assignee)
      event = create(:ticket_event, ticket: ticket, actor: actor, action: "assigned",
                                    data: { "assignee" => { "from" => nil, "to" => assignee.name } })
      dispatch(event)
      expect(Alerting::Notification.where(account: assignee, via: :in_app, event_type: :ticket_assigned)).to exist
    end
  end

  describe "evento milestone_changed" do
    it "notifica i watcher con event_type ticket_milestone_changed" do
      Ticketing::Subscription.ensure_for(ticket: ticket, account: watcher, source: :manual)
      event = create(:ticket_event, ticket: ticket, actor: actor, action: "milestone_changed",
                                    data: { "milestone" => { "from" => nil, "to" => "v1" } })
      dispatch(event)
      expect(Alerting::Notification.where(account: watcher, event_type: :ticket_milestone_changed, via: :in_app)).to exist
    end
  end

  describe "guardie difensive" do
    it "evento senza ticket (ticket sparito) → no-op (Result.ok 0)" do
      event = create(:ticket_event, ticket: ticket, actor: actor, action: "status_changed")
      allow(event).to receive(:ticket).and_return(nil)

      result = dispatch(event)

      expect(result).to be_ok
      expect(result.value).to eq(0)
    end

    it "evento assigned su ticket SENZA assegnatario → auto-subscribe salta (nessun crash)" do
      event = create(:ticket_event, ticket: ticket, actor: actor, action: "assigned",
                                    data: { "assignee" => { "from" => nil, "to" => nil } })

      expect { dispatch(event) }.not_to raise_error
      expect(ticket.subscriptions.where(source: :assignee)).not_to exist
    end
  end

  # Ping dedicato "pronto per la revisione": SOLO all'ingresso in uno status review_gate, al reviewer.
  describe "ingresso in uno status review_gate → ping al reviewer" do
    let(:reviewer) do
      create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :member) }
    end
    # attore del cambio, diverso dal reviewer (altrimenti nessuna auto-notifica)
    let(:mover) do
      create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :member) }
    end
    let(:review_status) { create(:ticket_status, organization: organization, review_gate: true) }
    let(:plain_status)  { create(:ticket_status, organization: organization, review_gate: false) }

    def status_event(to_label)
      create(:ticket_event, ticket: ticket, actor: mover, action: "status_changed",
                            data: { "status" => { "from" => "Open", "to" => to_label } })
    end

    before { ticket.update!(reviewer: reviewer) }

    it "notifica il reviewer con event_type ticket_review_requested (in-app + email)" do
      ticket.update!(status: review_status)
      dispatch(status_event(review_status.label))
      expect(Alerting::Notification.where(account: reviewer, event_type: :ticket_review_requested, via: :in_app)).to exist
      expect(Alerting::Notification.where(account: reviewer, event_type: :ticket_review_requested, via: :email)).to exist
    end

    it "status NON review_gate → nessun ping di revisione" do
      ticket.update!(status: plain_status)
      dispatch(status_event(plain_status.label))
      expect(Alerting::Notification.where(event_type: :ticket_review_requested)).not_to exist
    end

    it "il reviewer NON riceve anche lo status_changed generico (no doppione)" do
      ticket.update!(status: review_status)
      Ticketing::Subscription.ensure_for(ticket: ticket, account: reviewer, source: :manual)
      dispatch(status_event(review_status.label))
      expect(Alerting::Notification.where(account: reviewer, event_type: :ticket_status_changed)).not_to exist
      expect(Alerting::Notification.where(account: reviewer, event_type: :ticket_review_requested, via: :in_app)).to exist
    end

    it "reviewer == attore del cambio → nessuna auto-notifica" do
      ticket.update!(status: review_status, reviewer: mover)
      dispatch(status_event(review_status.label))
      expect(Alerting::Notification.where(account: mover, event_type: :ticket_review_requested)).not_to exist
    end

    it "ticket senza reviewer → nessun ping" do
      ticket.update!(status: review_status, reviewer: nil)
      dispatch(status_event(review_status.label))
      expect(Alerting::Notification.where(event_type: :ticket_review_requested)).not_to exist
    end

    it "cadenza email off per la review → nessuna email di ping, ma l'in-app resta" do
      ticket.update!(status: review_status)
      create(:alerting_preference, account: reviewer, organization: organization,
                                   email_cadences: { "ticket_review_requested" => "off" })
      dispatch(status_event(review_status.label))
      expect(Alerting::Notification.where(account: reviewer, event_type: :ticket_review_requested, via: :in_app)).to exist
      expect(Alerting::Notification.where(account: reviewer, event_type: :ticket_review_requested, via: :email)).not_to exist
    end

    it "re-dispatch dello stesso evento → nessun duplicato (dedup :review)" do
      ticket.update!(status: review_status)
      event = status_event(review_status.label)
      dispatch(event)
      expect { dispatch(event) }.not_to change(Alerting::Notification, :count)
    end

    it "in-app di revisione sempre attiva anche col vecchio flag in_app_enabled = false" do
      ticket.update!(status: review_status)
      create(:alerting_preference, account: reviewer, organization: organization, in_app_enabled: false)
      dispatch(status_event(review_status.label))
      expect(Alerting::Notification.where(account: reviewer, event_type: :ticket_review_requested, via: :in_app)).to exist
    end

    it "reviewer con email_enabled = false → solo ping in-app di revisione" do
      ticket.update!(status: review_status)
      create(:alerting_preference, account: reviewer, organization: organization, email_enabled: false)
      dispatch(status_event(review_status.label))
      expect(Alerting::Notification.where(account: reviewer, event_type: :ticket_review_requested, via: :in_app)).to exist
      expect(Alerting::Notification.where(account: reviewer, event_type: :ticket_review_requested, via: :email)).not_to exist
    end
  end

  # Ping dedicato "review respinta": all'assignee (chi deve sistemare), body = motivo del rifiuto.
  describe "evento review_rejected → ping all'assignee col motivo" do
    let(:assignee) do
      create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :member) }
    end
    let(:rejecter) do
      create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :member) }
    end
    let(:reason) { "Manca il test sul caso limite" }

    def rejected_event
      create(:ticket_event, ticket: ticket, actor: rejecter, action: "review_rejected",
                            data: { "status" => { "from" => "In Review", "to" => "In Progress" },
                                    "reason" => reason })
    end

    before { ticket.update!(assignee: assignee) }

    it "notifica l'assignee con event_type ticket_review_rejected e il motivo nel body (in-app + email)" do
      dispatch(rejected_event)
      in_app = Alerting::Notification.find_by(account: assignee, event_type: :ticket_review_rejected, via: :in_app)
      expect(in_app).to be_present
      expect(in_app.body).to eq(reason)
      expect(Alerting::Notification.where(account: assignee, event_type: :ticket_review_rejected, via: :email)).to exist
    end

    it "l'assignee NON riceve anche la notifica generica (no doppione)" do
      Ticketing::Subscription.ensure_for(ticket: ticket, account: assignee, source: :manual)
      dispatch(rejected_event)
      expect(Alerting::Notification.where(account: assignee, event_type: :ticket_review_rejected).count).to eq(2)
    end

    it "i watcher ricevono la notifica generica ticket_review_rejected, l'attore mai" do
      Ticketing::Subscription.ensure_for(ticket: ticket, account: watcher, source: :manual)
      dispatch(rejected_event)
      expect(Alerting::Notification.where(account: watcher, event_type: :ticket_review_rejected, via: :in_app)).to exist
      expect(Alerting::Notification.where(account: rejecter)).not_to exist
    end

    it "assignee == attore del rifiuto → nessun ping dedicato" do
      ticket.update!(assignee: rejecter)
      dispatch(rejected_event)
      expect(Alerting::Notification.where(account: rejecter)).not_to exist
    end

    it "ticket senza assignee → nessun ping dedicato, resta il giro watcher" do
      ticket.update!(assignee: nil)
      Ticketing::Subscription.ensure_for(ticket: ticket, account: watcher, source: :manual)
      dispatch(rejected_event)
      expect(Alerting::Notification.where(account: watcher, event_type: :ticket_review_rejected)).to exist
    end

    it "cadenza email off per l'assignee → nessuna email di ping, ma l'in-app resta" do
      create(:alerting_preference, account: assignee, organization: organization,
                                   email_cadences: { "ticket_review_rejected" => "off" })
      dispatch(rejected_event)
      expect(Alerting::Notification.where(account: assignee, event_type: :ticket_review_rejected, via: :in_app)).to exist
      expect(Alerting::Notification.where(account: assignee, event_type: :ticket_review_rejected, via: :email)).not_to exist
    end

    it "re-dispatch dello stesso evento → nessun duplicato (dedup :review_rejected)" do
      event = rejected_event
      dispatch(event)
      expect { dispatch(event) }.not_to change(Alerting::Notification, :count)
    end
  end

  describe "evento review_approved → notifica generica ai watcher" do
    let(:approver) do
      create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :member) }
    end

    def approved_event
      create(:ticket_event, ticket: ticket, actor: approver, action: "review_approved",
                            data: { "status" => { "from" => "In Review", "to" => "Resolved" } })
    end

    before { Ticketing::Subscription.ensure_for(ticket: ticket, account: watcher, source: :manual) }

    it "notifica i watcher con event_type ticket_review_approved ed ESCLUDE l'attore" do
      dispatch(approved_event)
      expect(Alerting::Notification.where(account: watcher, event_type: :ticket_review_approved, via: :in_app)).to exist
      expect(Alerting::Notification.where(account: approver)).not_to exist
    end

    it "cadenza email off → nessuna email, ma l'in-app resta" do
      create(:alerting_preference, account: watcher, organization: organization,
                                   email_cadences: { "ticket_review_approved" => "off" })
      dispatch(approved_event)
      expect(Alerting::Notification.where(account: watcher, via: :in_app)).to exist
      expect(Alerting::Notification.where(account: watcher, via: :email)).not_to exist
    end
  end
end
