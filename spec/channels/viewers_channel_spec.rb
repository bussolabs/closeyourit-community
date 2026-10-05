# frozen_string_literal: true

require "rails_helper"

# ViewersChannel (Task D2): conteggio realtime "chi sta guardando" ticket/monitor. Copre:
#  - subscribed: stream_from org-prefissato + registrazione viewer + broadcast del badge sul target;
#  - touch (heartbeat): rinfresca il TTL senza ribroadcastare;
#  - unsubscribed: decremento + broadcast;
#  - anti-BOLA sulla risoluzione del gid NON firmato (org altrui / classe non in allowlist / malformato).
# Store del registry iniettato (in test il cache_store dell'app è :null_store). I broadcast Turbo si
# leggono come stream String, come negli altri *_broadcast_spec dell'app.
RSpec.describe ViewersChannel, type: :channel do
  let(:organization) { create(:organization) }
  let(:account) { create(:account) }
  let!(:membership) { create(:membership, account: account, organization: organization) }
  let(:project) { create(:project, organization: organization) }
  let!(:project_access) { create(:project_membership, account: account, project: project) }
  let(:ticket) { create(:ticket, organization: organization, project: project) }
  let(:monitor) { create(:uptime_monitor, project: project) }
  let(:stream) { Realtime::Streams.viewers(organization, ticket) }

  around do |example|
    previous = Realtime::ViewersRegistry.store
    Realtime::ViewersRegistry.store = ActiveSupport::Cache::MemoryStore.new
    example.run
    Realtime::ViewersRegistry.store = previous
  end

  before { stub_connection(live_account: account, current_account: account, current_organization: organization) }

  describe "#subscribed (ticket)" do
    it "si sottoscrive allo stream viewers org-prefissato della risorsa" do
      subscribe(resource: ticket.to_gid_param)

      expect(subscription).to be_confirmed
      expect(subscription).to have_stream_from(stream)
    end

    it "registra il viewer corrente (conteggio 1)" do
      subscribe(resource: ticket.to_gid_param)

      expect(Realtime::ViewersRegistry.count(stream)).to eq(1)
    end

    it "broadcasta il badge sul target viewers_<gid>" do
      expect { subscribe(resource: ticket.to_gid_param) }
        .to have_broadcasted_to(stream)
        .with(a_string_including("viewers_#{ticket.to_gid_param}"))
    end

    it "il broadcast contiene il testo i18n del conteggio" do
      expect { subscribe(resource: ticket.to_gid_param) }
        .to have_broadcasted_to(stream)
        .with(a_string_including(I18n.t("member.presence.viewers_count", count: 1)))
    end
  end

  describe "#subscribed (monitor)" do
    it "vale anche per i monitor (allowlist) e usa lo stream del monitor" do
      subscribe(resource: monitor.to_gid_param)

      expect(subscription).to be_confirmed
      expect(subscription).to have_stream_from(Realtime::Streams.viewers(organization, monitor))
    end
  end

  describe "#subscribed — anti-BOLA / risorse non valide" do
    it "RIFIUTA un ticket di un'ALTRA organizzazione" do
      foreign = create(:ticket, organization: create(:organization))

      subscribe(resource: foreign.to_gid_param)

      expect(subscription).to be_rejected
    end

    it "RIFIUTA un gid di classe non in allowlist (Account)" do
      subscribe(resource: account.to_gid_param)

      expect(subscription).to be_rejected
    end

    it "RIFIUTA un resource param malformato" do
      subscribe(resource: "not-a-gid")

      expect(subscription).to be_rejected
    end

    it "RIFIUTA un gid di risorsa inesistente (find solleva → rescue)" do
      gid = ticket.to_gid_param
      ticket.destroy

      subscribe(resource: gid)

      expect(subscription).to be_rejected
    end

    it "RIFIUTA senza organizzazione corrente" do
      stub_connection(live_account: account, current_account: account, current_organization: nil)

      subscribe(resource: ticket.to_gid_param)

      expect(subscription).to be_rejected
    end

    it "una risorsa rifiutata non registra alcun viewer" do
      subscribe(resource: account.to_gid_param)

      expect(Realtime::ViewersRegistry.count(stream)).to eq(0)
    end

    it "non broadcasta sullo stream viewers di un'altra org" do
      other_org_stream = Realtime::Streams.viewers(create(:organization), ticket)

      expect { subscribe(resource: ticket.to_gid_param) }.not_to have_broadcasted_to(other_org_stream)
    end
  end

  describe "#touch (heartbeat)" do
    it "stops renewing presence after project access is revoked" do
      subscribe(resource: ticket.to_gid_param)
      project_access.destroy!

      travel(40.seconds) { perform("touch") }
      travel(60.seconds) { expect(Realtime::ViewersRegistry.count(stream)).to eq(0) }
    end

    it "rinfresca il TTL senza ribroadcastare" do
      subscribe(resource: ticket.to_gid_param)

      expect { perform("touch") }.not_to have_broadcasted_to(stream)
      expect(Realtime::ViewersRegistry.count(stream)).to eq(1)
    end

    it "tiene vivo il viewer oltre il TTL iniziale" do
      subscribe(resource: ticket.to_gid_param)

      travel(40.seconds) { perform("touch") }
      travel(60.seconds) { expect(Realtime::ViewersRegistry.count(stream)).to eq(1) }
    end

    it "senza heartbeat il viewer scade per TTL" do
      subscribe(resource: ticket.to_gid_param)

      travel(60.seconds) { expect(Realtime::ViewersRegistry.count(stream)).to eq(0) }
    end

    it "senza stream risolto (subscription non confermata) → no-op (guard)" do
      subscribe(resource: ticket.to_gid_param)
      subscription.instance_variable_set(:@stream, nil)

      expect { perform("touch") }.not_to have_broadcasted_to(stream)
    end
  end

  describe "#unsubscribed" do
    it "decrementa il conteggio e broadcasta il nuovo valore" do
      subscribe(resource: ticket.to_gid_param)

      expect { unsubscribe }.to have_broadcasted_to(stream)
      expect(Realtime::ViewersRegistry.count(stream)).to eq(0)
    end
  end
end
