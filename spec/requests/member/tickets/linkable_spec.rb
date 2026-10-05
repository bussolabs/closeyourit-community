# frozen_string_literal: true

require "rails_helper"

# CYRA-364 — l'endpoint che rifornisce il campo «Ticket collegato» mentre si digita.
# Due team, un progetto ciascuno: è la condizione minima per distinguere «ristretto al contesto»
# da «ristretto alla visibilità», che qui sono due cose diverse.
RSpec.describe "Member::Tickets::Linkable", type: :request do
  let(:org) { create(:organization) }
  let(:account) { create(:account) }
  let(:project) { create(:project, organization: org, key: "CYRA") }
  let(:altro_progetto) { create(:project, organization: org, key: "PFCL") }
  let(:team) { create(:team, organization: org) }
  let(:altro_team) { create(:team, organization: org) }

  before do
    create(:membership, account: account, organization: org, role: :member)
    create(:team_membership, team: team, account: account)
    create(:team_membership, team: altro_team, account: account)
    create(:team_project_access, team: team, project: project)
    create(:team_project_access, team: altro_team, project: altro_progetto)
  end

  def sign_in(who)
    post login_path, params: { email: who.email, password: "Secret123!" }
  end

  def labels
    response.parsed_body["data"].map { |voce| voce["label"] }
  end

  it "non autenticato → redirect login" do
    get linkable_member_tickets_path
    expect(response).to redirect_to(login_path)
  end

  it "risponde con codice e titolo dei ticket che corrispondono" do
    sign_in(account)
    cercato = create(:ticket, organization: org, project:, title: "Il collegamento è lento")
    create(:ticket, organization: org, project:, title: "Tutt'altro")

    get linkable_member_tickets_path, params: { q: "collegamento" }

    expect(response).to have_http_status(:ok)
    expect(labels).to contain_exactly("#{cercato.code} · #{cercato.title}")
  end

  it "senza query dà comunque le poche voci recenti, non l'archivio intero" do
    sign_in(account)
    allow_n_plus_one { create_list(:ticket, 10, organization: org, project:) }

    get linkable_member_tickets_path

    expect(response.parsed_body["data"].size).to eq(Ticketing::LinkableTickets::LIMIT)
  end

  # Il contesto è il team scelto nel form: restringe ai progetti a cui quel team ha accesso, anche
  # quando chi cerca ne vedrebbe altri.
  it "col team di contesto lascia fuori i progetti che quel team non vede" do
    sign_in(account)
    dentro = create(:ticket, organization: org, project:, title: "Dentro")
    fuori = create(:ticket, organization: org, project: altro_progetto, title: "Fuori")

    get linkable_member_tickets_path, params: { team_id: team.id }

    expect(labels).to include("#{dentro.code} · #{dentro.title}")
    expect(labels).not_to include("#{fuori.code} · #{fuori.title}")
  end

  it "con all allarga oltre il contesto, quando lo si chiede" do
    sign_in(account)
    fuori = create(:ticket, organization: org, project: altro_progetto, title: "Fuori")

    get linkable_member_tickets_path, params: { team_id: team.id, all: "1" }

    expect(labels).to include("#{fuori.code} · #{fuori.title}")
  end

  # Anti-BOLA: un team altrui non è un perimetro che si possa chiedere — e non allarga niente,
  # perché la visibilità resta quella di chi cerca.
  it "un team a cui non appartengo non decide cosa vedo" do
    sign_in(account)
    estraneo = create(:team, organization: org)
    create(:team_project_access, team: estraneo, project:)
    mio = create(:ticket, organization: org, project: altro_progetto, title: "Visibile a me")

    get linkable_member_tickets_path, params: { team_id: estraneo.id }

    expect(labels).to include("#{mio.code} · #{mio.title}")
  end

  it "un ticket che non vedo non compare, nemmeno cercandolo per codice" do
    sign_in(account)
    fuori_org = create(:ticket, organization: create(:organization), title: "Di un'altra organizzazione")

    get linkable_member_tickets_path, params: { q: fuori_org.code }

    expect(labels).to be_empty
  end
end
