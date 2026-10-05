# frozen_string_literal: true

require "rails_helper"

# Wiring runtime della presenza nel layout member: la home autenticata sottoscrive lo stream
# presence PER-ACCOUNT (Realtime::Streams.presence_for), non più uno stream org-wide condiviso che
# mostrava l'intera org a tutti. Prova che il fix (member.html.erb) rende esattamente la
# subscription firmata attesa, attraverso l'intero stack (routing → controller → layout ERB →
# turbo_stream_from). Il FILTRO di chi appare è coperto da Presence::Cohort/Broadcast; qui si prova
# solo che ogni viewer si aggancia al proprio canale.
RSpec.describe "Member presence layout wiring", type: :request do
  let(:org) { create(:organization) }
  let(:member) { create(:account) }
  let(:owner) { create(:account) }

  before do
    create(:membership, account: member, organization: org, role: :member)
    create(:membership, account: owner, organization: org, role: :owner)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def signed(viewer)
    Turbo::StreamsChannel.signed_stream_name(Realtime::Streams.presence_for(org, viewer))
  end

  it "sottoscrive lo stream presence PER-ACCOUNT del viewer e monta il controller Stimulus" do
    sign_in(member)
    get root_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-controller="presence"')
    expect(response.body).to include('data-test="presence-list"')
    expect(response.body).to include(%(signed-stream-name="#{signed(member)}"))
  end

  it "viewer diversi ottengono stream presence diversi (isolamento per-account)" do
    sign_in(member)
    get root_path

    expect(response.body).to include(%(signed-stream-name="#{signed(member)}"))
    expect(response.body).not_to include(%(signed-stream-name="#{signed(owner)}"))
  end

  it "renders who is already online, so the count does not start from zero on every page" do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    Realtime::Presence.add(org, member)
    Realtime::Presence.add(org, owner)
    sign_in(owner)

    get root_path

    expect(response.body).to include('data-test="presence-count"')
    expect(response.body).to include(%(data-test="presence-avatar-#{member.id} presence-preview-slot"))
  end

  it "account senza organizzazione: nessuna subscription di presenza" do
    sign_in(create(:account)) # nessuna membership → nessun current_organization
    get root_path

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include('data-controller="presence"')
  end
end
