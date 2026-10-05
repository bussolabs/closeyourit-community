# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Telegram commands via webhook", type: :request do
  let(:secret) { "s3cr3t-webhook" }
  let(:org) { create(:organization) }
  let(:account) do
    create(:account, telegram_chat_id: "900", telegram_linked_at: Time.current)
      .tap { |a| create(:membership, account: a, organization: org, role: :owner) }
  end
  let!(:project) { create(:project, organization: org, key: "DRRA") }
  let!(:status) { create(:ticket_status, organization: org, code: "open", category: :open) }
  let!(:priority) { create(:ticket_priority, organization: org, code: "medium") }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("TELEGRAM_WEBHOOK_SECRET").and_return(secret)
    allow(Telegram::Send).to receive(:call).and_return(Result.ok(true))
  end

  def post_message(message)
    post "/telegram/webhook",
         params: { message: message }.to_json,
         headers: { "Content-Type" => "application/json", "X-Telegram-Bot-Api-Secret-Token" => secret }
  end

  it "/nuovo-ticket da account collegato crea il ticket (200)" do
    account
    expect { post_message({ text: "/nuovo-ticket DRRA il login non va", chat: { id: 900 } }) }
      .to change(Ticketing::Ticket, :count).by(1)

    expect(response).to have_http_status(:ok)
    expect(Ticketing::Ticket.last.reporter).to eq(account)
    expect(Ticketing::Ticket.last.project).to eq(project)
  end

  it "/nuovo-ticket da chat NON collegata → nessun ticket, guida al collegamento (200)" do
    expect { post_message({ text: "/nuovo-ticket DRRA testo", chat: { id: 12_345 } }) }
      .not_to change(Ticketing::Ticket, :count)

    expect(response).to have_http_status(:ok)
    expect(Telegram::Send).to have_received(:call)
      .with(hash_including(text: I18n.t("telegram.commands.link_required", locale: I18n.default_locale)))
  end

  it "/progetto imposta il progetto attivo dell'account (200)" do
    account
    post_message({ text: "/progetto DRRA", chat: { id: 900 } })

    expect(response).to have_http_status(:ok)
    expect(account.reload.telegram_project_id).to eq(project.id)
  end

  it "comando nella caption di una foto crea il ticket con allegato" do
    account.update!(telegram_project_id: project.id)
    upload = Rack::Test::UploadedFile.new(Rails.root.join("spec/fixtures/files/screenshot.png"), "image/png")
    allow(Telegram::DownloadFile).to receive(:call).and_return(Result.ok(upload))

    post_message({ caption: "/nuovo-ticket schermata dell'errore", chat: { id: 900 }, photo: [ { file_id: "BIG" } ] })

    expect(response).to have_http_status(:ok)
    expect(Ticketing::Ticket.last.files).to be_attached
  end

  it "comando sconosciuto da account collegato → rimando a /aiuto (200, nessun effetto)" do
    account
    expect { post_message({ text: "/pippo", chat: { id: 900 } }) }.not_to change(Ticketing::Ticket, :count)

    expect(response).to have_http_status(:ok)
    expect(Telegram::Send).to have_received(:call)
      .with(hash_including(text: I18n.t("telegram.commands.unknown", locale: account.effective_locale)))
  end

  it "/aiuto da account collegato → invia la guida comandi (200)" do
    account
    post_message({ text: "/aiuto", chat: { id: 900 } })

    expect(response).to have_http_status(:ok)
    expect(Telegram::Send).to have_received(:call)
      .with(hash_including(text: I18n.t("telegram.help.body", locale: account.effective_locale)))
  end

  it "/progetti elenca i progetti visibili (200)" do
    account
    post_message({ text: "/progetti", chat: { id: 900 } })

    expect(response).to have_http_status(:ok)
    expect(Telegram::Send).to have_received(:call).with(hash_including(text: include("DRRA")))
  end

  it "/miei-ticket risponde (200)" do
    account
    post_message({ text: "/miei-ticket", chat: { id: 900 } })

    expect(response).to have_http_status(:ok)
  end

  it "/ticket CODICE mostra lo stato del ticket (200)" do
    account
    ticket = create(:ticket, :plain_bug, organization: org, project: project, status: status, priority: priority)
    post_message({ text: "/ticket #{ticket.code}", chat: { id: 900 } })

    expect(response).to have_http_status(:ok)
    expect(Telegram::Send).to have_received(:call).with(hash_including(text: include(ticket.code)))
  end

  it "/commenta CODICE aggiunge un commento (200)" do
    account
    ticket = create(:ticket, :plain_bug, organization: org, project: project, status: status, priority: priority)
    expect { post_message({ text: "/commenta #{ticket.code} riprovato", chat: { id: 900 } }) }
      .to change { ticket.reload.comments.count }.by(1)

    expect(response).to have_http_status(:ok)
  end
end
