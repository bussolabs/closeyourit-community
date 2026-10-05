# frozen_string_literal: true

require "rails_helper"
require "timeout"

# CYRA-806 — la concessione device-flow è dichiarata monouso, e "monouso" deve valere anche quando due
# poll arrivano insieme. Qui serve PostgreSQL vero, senza la transazione di test intorno: ciò che regge
# l'invariante è il lock di riga della UPDATE condizionata, e dentro una transazione sola non ci sarebbe
# nessuna corsa da vincere.
RSpec.describe Accounts::Devices::Poll, "concorrenza PostgreSQL reale" do
  self.use_transactional_tests = false

  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:device_code) { "dc-simultaneo" }
  let!(:grant) do
    create(:device_grant, :approved, account:, organization:,
                                     device_code_digest: Digest::SHA256.hexdigest(device_code))
  end

  after do
    Accounts::DeviceGrant.where(id: grant.id).delete_all
    organization.destroy! if organization.persisted?
    account.destroy! if account.persisted?
  end

  it "due poll simultanei sulla stessa concessione rilasciano UNA sola credenziale" do
    waiting = 0
    mutex = Mutex.new
    barrier = ConditionVariable.new
    threads = []

    # Il punto della corsa è a valle della lettura: entrambe hanno in mano la stessa concessione
    # `approved` e lo stesso `last_polled_at` vecchio, quindi superano tutte e due le guardie.
    allow_any_instance_of(described_class).to receive(:too_fast?).and_wrap_original do |original, snapshot|
      mutex.synchronize do
        waiting += 1
        barrier.broadcast
        barrier.wait(mutex) while waiting < 2
      end
      original.call(snapshot)
    end

    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection { described_class.call(device_code:) }
      end
    end
    results = Timeout.timeout(10) { threads.map(&:value) }

    vincitrice = results.select(&:ok?)
    perdenti = results.select(&:err?)
    expect(vincitrice.size).to eq(1)
    expect(perdenti.size).to eq(1)
    expect(perdenti.first.error.code).to eq("R400-CLIAUTH-005")
    expect(perdenti.first.error.details[:oauth_error]).to eq("access_denied")

    # Nessuna seconda credenziale: quella coniata da chi ha perso torna indietro col rollback.
    sopravvissuta = Accounts::ApiToken.where(account:).sole
    grant.reload
    expect(grant).to be_fulfilled
    expect(grant.api_token).to eq(sopravvissuta)
    expect(sopravvissuta.token_digest)
      .to eq(Digest::SHA256.hexdigest(vincitrice.first.value[:access_token]))
  ensure
    threads.each do |thread|
      thread.kill if thread.alive?
      thread.join
    end
  end
end
