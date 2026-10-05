# frozen_string_literal: true

require "rails_helper"

RSpec.describe Chat::References::Parse do
  let(:org) { create(:organization) }
  let(:shared) { create(:project, organization: org) }   # visto da entrambi
  let(:private_a) { create(:project, organization: org) } # visto solo da A

  def member_seeing(*projects)
    account = create(:account)
    create(:membership, account: account, organization: org, role: :member)
    projects.each { |project| create(:project_membership, account: account, project: project) }
    account
  end

  let(:account_a) { member_seeing(shared, private_a) }
  let(:account_b) { member_seeing(shared) }
  let(:participants) { [ account_a, account_b ] } # intersezione = [shared]

  def parse(text)
    described_class.call(text: text, organization: org, participants: participants)
  end

  it "risolve un ticket via #KEY-NUMERO se nel progetto comune" do
    ticket = create(:ticket, organization: org, project: shared)
    expect(parse("guarda ##{ticket.code} grazie")).to include(ticket)
  end

  it "scarta un ticket di un progetto che non tutti vedono" do
    ticket = create(:ticket, organization: org, project: private_a)
    expect(parse("guarda ##{ticket.code}")).to be_empty
  end

  it "risolve un progetto via token cyi:project:<id> se comune" do
    expect(parse("il canale cyi:project:#{shared.id} è attivo")).to include(shared)
  end

  it "scarta un progetto non comune anche col token esplicito" do
    expect(parse("cyi:project:#{private_a.id}")).to be_empty
  end

  it "risolve un error group del progetto comune" do
    group = create(:error_group, project: shared)
    expect(parse("errore cyi:error:#{group.id}")).to include(group)
  end

  it "risolve più risorse e deduplica" do
    ticket = create(:ticket, organization: org, project: shared)
    group = create(:metric_group, project: shared)
    text = "##{ticket.code} e cyi:metric:#{group.id} e di nuovo ##{ticket.code}"
    result = parse(text)
    expect(result).to contain_exactly(ticket, group)
  end

  it "ignora token verso risorse inesistenti" do
    expect(parse("cyi:ticket:00000000-0000-0000-0000-000000000000")).to be_empty
  end

  it "testo vuoto o senza tag → nessun risultato e nessun calcolo CommonScope" do
    expect(Chat::CommonScope).not_to receive(:new)
    expect(parse("")).to be_empty
    expect(parse("nessun riferimento qui")).to be_empty
  end

  it "risolve il tag a inizio e a fine stringa" do
    ticket = create(:ticket, organization: org, project: shared)
    expect(parse("##{ticket.code} in testa")).to include(ticket)
    expect(parse("in coda ##{ticket.code}")).to include(ticket)
  end

  it "risolve il #code in minuscolo (case-insensitive)" do
    ticket = create(:ticket, organization: org, project: shared)
    expect(parse("guarda ##{ticket.code.downcase}")).to include(ticket)
  end

  it "NON matcha un # incollato a una parola/trattino (lookbehind)" do
    ticket = create(:ticket, organization: org, project: shared)
    expect(parse("x-##{ticket.code}")).to be_empty
    expect(parse("word##{ticket.code}")).to be_empty
  end

  it "ignora un token cyi: con uuid malformato" do
    expect(parse("cyi:ticket:non-un-uuid")).to be_empty
  end

  it "deduplica lo stesso ticket taggato via #CODE e via token cyi:" do
    ticket = create(:ticket, organization: org, project: shared)
    result = parse("##{ticket.code} e cyi:ticket:#{ticket.id}")
    expect(result).to contain_exactly(ticket)
  end

  it "scarta un record di un'ALTRA organizzazione anche con uuid noto (difesa in profondità)" do
    other_org = create(:organization)
    foreign_project = create(:project, organization: other_org)
    foreign_ticket = create(:ticket, organization: other_org, project: foreign_project)
    expect(parse("cyi:ticket:#{foreign_ticket.id}")).to be_empty
  end

  it "risolve log entry e uptime monitor del progetto comune (tutti i tipi whitelisted)" do
    log = create(:log_entry, project: shared)
    monitor = create(:uptime_monitor, project: shared)
    expect(parse("cyi:log:#{log.id} e cyi:uptime:#{monitor.id}")).to contain_exactly(log, monitor)
  end
end
