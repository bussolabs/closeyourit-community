# frozen_string_literal: true

require "rails_helper"

# Partial di montaggio del badge viewer: wrapper col controller Stimulus `viewers` (gid della risorsa)
# + target iniziale. È la riga che l'integrazione monta nelle show di ticket/monitor. Store del registry
# iniettato (cache_store di test = :null_store) → all'avvio nessun viewer registrato → badge nascosto.
RSpec.describe "member/viewers/_badge", type: :view do
  around do |example|
    previous = Realtime::ViewersRegistry.store
    Realtime::ViewersRegistry.store = ActiveSupport::Cache::MemoryStore.new
    example.run
    Realtime::ViewersRegistry.store = previous
  end

  it "monta il controller Stimulus `viewers` col gid della risorsa (ticket)" do
    ticket = create(:ticket)

    render partial: "member/viewers/badge", locals: { resource: ticket }

    expect(rendered).to include('data-controller="viewers"')
    expect(rendered).to include(%(data-viewers-resource-value="#{ticket.to_gid_param}"))
    expect(rendered).to include('data-test="viewers-badge"')
    expect(rendered).to include(%(id="viewers_#{ticket.to_gid_param}"))
  end

  it "vale anche per il monitor" do
    monitor = create(:uptime_monitor)

    render partial: "member/viewers/badge", locals: { resource: monitor }

    expect(rendered).to include(%(data-viewers-resource-value="#{monitor.to_gid_param}"))
    expect(rendered).to include(%(id="viewers_#{monitor.to_gid_param}"))
  end

  it "all'avvio (nessun viewer registrato) il badge è nascosto" do
    ticket = create(:ticket)

    render partial: "member/viewers/badge", locals: { resource: ticket }

    expect(rendered).not_to include('data-test="viewers-count"')
  end
end
