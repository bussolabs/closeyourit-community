# frozen_string_literal: true

require "rails_helper"

RSpec.describe Telegram::ListProjects do
  let(:org) { create(:organization) }

  before { allow(Telegram::Send).to receive(:call).and_return(Result.ok(true)) }

  it "elenca i progetti visibili con la loro chiave" do
    owner = create(:account, telegram_chat_id: "555").tap { |a| create(:membership, account: a, organization: org, role: :owner) }
    create(:project, organization: org, key: "AAAA", name: "Alpha")
    create(:project, organization: org, key: "BBBB", name: "Beta")

    described_class.call(account: owner, chat_id: "555")

    expect(Telegram::Send).to have_received(:call)
      .with(hash_including(text: include("AAAA").and(include("BBBB")).and(include("Alpha"))))
  end

  # CYRA-722 — il bot è un'altra porta della stessa organizzazione: se è sospesa, da lì non si
  # elencano i suoi progetti, non se ne aprono ticket e non se ne leggono.
  it "i progetti di un'organizzazione sospesa non compaiono" do
    sospesa = create(:organization, suspended_at: Time.current)
    owner = create(:account, telegram_chat_id: "557")
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: owner, organization: sospesa, role: :owner)
    create(:project, organization: org, key: "AAAA", name: "Alpha")
    create(:project, organization: sospesa, key: "ZZZZ", name: "Zeta")

    described_class.call(account: owner, chat_id: "557")

    expect(Telegram::Send).to have_received(:call)
      .with(hash_including(text: include("AAAA")))
    expect(Telegram::Send).not_to have_received(:call).with(hash_including(text: include("ZZZZ")))
  end

  it "nessun progetto visibile → messaggio vuoto" do
    member = create(:account, telegram_chat_id: "556").tap { |a| create(:membership, account: a, organization: org, role: :member) }
    create(:project, organization: org, key: "AAAA") # esiste ma il member non ha accesso

    described_class.call(account: member, chat_id: "556")

    expect(Telegram::Send).to have_received(:call)
      .with(hash_including(text: I18n.t("telegram.projects.empty", locale: member.effective_locale)))
  end
end
