# frozen_string_literal: true

require "rails_helper"

RSpec.describe Telegram::CreateTicketFromMessage do
  let(:org) { create(:organization) }
  let(:account) do
    create(:account, telegram_chat_id: "555", telegram_linked_at: Time.current)
      .tap { |a| create(:membership, account: a, organization: org, role: :owner) }
  end
  let!(:project) { create(:project, organization: org, key: "DRRA") }
  let!(:status) { create(:ticket_status, organization: org, code: "open", category: :open) }
  let!(:priority) { create(:ticket_priority, organization: org, code: "medium") }

  before { allow(Telegram::Send).to receive(:call).and_return(Result.ok(true)) }

  def run(args, message: nil)
    described_class.call(account: account, chat_id: "555", args: args, message: message)
  end

  it "con chiave esplicita apre un bug nel progetto (titolo = prima riga, descrizione = tutto il testo)" do
    expect { run("DRRA il login non va") }.to change(Ticketing::Ticket, :count).by(1)

    ticket = Ticketing::Ticket.last
    expect(ticket.project).to eq(project)
    expect(ticket).to be_kind_bug
    expect(ticket.reporter).to eq(account)
    expect(ticket.title).to eq("il login non va")
    expect(ticket.description).to eq("il login non va")
    expect(ticket.status.code).to eq("open")
    expect(ticket.priority.code).to eq("medium")
    expect(Telegram::Send).to have_received(:call).with(hash_including(text: include(ticket.code)))
  end

  it "senza chiave usa il progetto attivo dell'account" do
    account.update!(telegram_project_id: project.id)
    expect { run("il checkout crasha su Safari") }.to change(Ticketing::Ticket, :count).by(1)
    expect(Ticketing::Ticket.last.project).to eq(project)
    expect(Ticketing::Ticket.last.description).to eq("il checkout crasha su Safari")
  end

  it "multi-riga: titolo = prima riga, descrizione = testo intero" do
    run("DRRA Login rotto\nSuccede solo in produzione")
    ticket = Ticketing::Ticket.last
    expect(ticket.title).to eq("Login rotto")
    expect(ticket.description).to eq("Login rotto\nSuccede solo in produzione")
  end

  it "una parola corta in maiuscolo che NON è una chiave non viene scambiata per chiave" do
    account.update!(telegram_project_id: project.id)
    run("API non risponde più")
    ticket = Ticketing::Ticket.last
    expect(ticket.project).to eq(project)
    expect(ticket.description).to eq("API non risponde più")
  end

  it "tronca il titolo lungo a 120 caratteri (descrizione integra)" do
    account.update!(telegram_project_id: project.id)
    long = "x" * 200
    run(long)
    ticket = Ticketing::Ticket.last
    expect(ticket.title.length).to be <= 120
    expect(ticket.description).to eq(long)
  end

  it "tronca un messaggio più lungo del tetto invece di rifiutare la segnalazione" do
    account.update!(telegram_project_id: project.id)

    expect { run("y" * (Ticketing::Constants::DESCRIPTION_MAX_CHARS + 500)) }
      .to change(Ticketing::Ticket, :count).by(1)
    expect(Ticketing::Ticket.last.description.length).to eq(Ticketing::Constants::DESCRIPTION_MAX_CHARS)
  end

  it "testo vuoto → nessun ticket, invita a scrivere il testo" do
    expect { run("") }.not_to change(Ticketing::Ticket, :count)
    expect(Telegram::Send).to have_received(:call)
      .with(hash_including(text: I18n.t("telegram.ticket.empty", locale: account.effective_locale)))
  end

  it "nessun progetto attivo e nessuna chiave → nessun ticket, chiede di impostarlo" do
    expect { run("qualcosa non va") }.not_to change(Ticketing::Ticket, :count)
    expect(Telegram::Send).to have_received(:call)
      .with(hash_including(text: I18n.t("telegram.ticket.no_project", locale: account.effective_locale)))
  end

  describe "con foto in caption" do
    let(:message) { { "photo" => [ { "file_id" => "SMALL" }, { "file_id" => "BIG" } ] } }
    let(:upload) { Rack::Test::UploadedFile.new(Rails.root.join("spec/fixtures/files/screenshot.png"), "image/png") }

    before { account.update!(telegram_project_id: project.id) }

    it "scarica la foto (risoluzione più grande) e la allega al ticket" do
      expect(Telegram::DownloadFile).to receive(:call).with(file_id: "BIG", filename: nil).and_return(Result.ok(upload))

      run("schermata dell'errore", message: message)

      ticket = Ticketing::Ticket.last
      expect(ticket.files).to be_attached
      expect(Telegram::Send).to have_received(:call).with(hash_including(text: include(ticket.code)))
    end

    it "se il download della foto fallisce il ticket è comunque creato (senza allegato)" do
      allow(Telegram::DownloadFile).to receive(:call).and_return(Result.err(AppError.new("giù", code: "R502-TELEGRAM-004", status: :bad_gateway)))

      expect { run("schermata", message: message) }.to change(Ticketing::Ticket, :count).by(1)
      expect(Ticketing::Ticket.last.files).not_to be_attached
    end

    it "un documento (non foto) viene estratto con file_id e nome e allegato" do
      document = { "document" => { "file_id" => "DOC1", "file_name" => "log.txt" } }
      expect(Telegram::DownloadFile).to receive(:call).with(file_id: "DOC1", filename: "log.txt").and_return(Result.ok(upload))

      run("vedi il log", message: document)
      expect(Ticketing::Ticket.last.files).to be_attached
    end
  end

  it "se la creazione fallisce (org senza status/priority) avvisa e non crea ticket" do
    bare_org = create(:organization)
    bare_account = create(:account, telegram_chat_id: "777")
                   .tap { |a| create(:membership, account: a, organization: bare_org, role: :owner) }
    bare_project = create(:project, organization: bare_org, key: "BARE")
    bare_account.update!(telegram_project_id: bare_project.id)

    result = described_class.call(account: bare_account, chat_id: "777", args: "qualcosa non va")

    expect(result).to be_err
    expect(result.error.code).to eq("R422-TICKET-001")
    expect(Ticketing::Ticket.where(project: bare_project)).to be_empty
    expect(Telegram::Send).to have_received(:call) # ha avvisato l'utente del fallimento
  end
end
