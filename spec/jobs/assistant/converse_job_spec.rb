# frozen_string_literal: true

require "rails_helper"

RSpec.describe Assistant::ConverseJob do
  let(:organization) { create(:organization) }
  let(:account) do
    create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :owner) }
  end
  let(:project) { create(:project, organization: organization, key: "CYRA") }
  let(:conversation) { Assistant::Conversation.create!(account: account, organization: organization, kind: :tools) }

  # Restituisce la coppia domanda/risposta come la crea il controller.
  def ask(text)
    question = conversation.messages.create!(organization: organization, role: :user,
                                             status: :complete, content: text)
    reply = conversation.messages.create!(organization: organization, role: :assistant, status: :streaming)
    [ question, reply ]
  end

  def run(pair, project_ids: [ project.id ], group_ids: [], full_access: false, scope_listed: true)
    question, reply = pair
    described_class.perform_now(message_id: reply.id, question_id: question.id,
                                project_ids: project_ids, group_ids: group_ids,
                                full_access: full_access, scope_listed: scope_listed)
    reply.reload
  end

  def answers(text:, tools: [])
    allow(Assistant::Converse).to receive(:call)
      .and_return(Result.ok(Assistant::Converse::Answer.new(text: text, tools_used: tools)))
  end

  it "scrive la risposta e gli attrezzi che ha usato" do
    answers(text: "Hai un progetto.", tools: %w[list_projects])

    reply = run(ask("che progetti ho?"))

    expect(reply).to be_status_complete
    expect(reply.content).to eq("Hai un progetto.")
    expect(reply.tools_used).to eq(%w[list_projects])
  end

  it "passa al servizio il perimetro ricevuto, non uno ricalcolato" do
    answers(text: "ok")
    create(:project, organization: organization, key: "ALTR") # visibile ORA, ma non all'invio

    run(ask("ciao"))

    expect(Assistant::Converse).to have_received(:call)
      .with(hash_including(context: have_attributes(project_ids: [ project.id ])))
  end

  # La knowledge base non appartiene a un progetto: senza gruppi e accesso pieno il perimetro
  # sarebbe monco proprio per l'attrezzo che le pagine le legge.
  it "porta nel perimetro anche i gruppi e l'accesso pieno" do
    answers(text: "ok")
    group = create(:group, organization: organization)

    run(ask("ciao"), group_ids: [ group.id ], full_access: true)

    expect(Assistant::Converse).to have_received(:call).with(
      hash_including(context: have_attributes(group_ids: [ group.id ], full_access: true))
    )
  end

  # CYRA-812 — il perimetro dell'invio è un tetto, non un lasciapassare: quello che viene tolto fra
  # la domanda e la risposta non si legge, e chi ha chiesto lo viene a sapere.
  describe "quando l'accesso cambia fra la domanda e la risposta" do
    let(:account) do
      create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :member) }
    end

    before { create(:project_membership, account: account, project: project) }

    it "non legge il progetto a cui l'accesso è stato revocato dopo l'invio" do
      answers(text: "ok")
      pair = ask("quanti ticket ho?")
      Connections::ProjectMembership.find_by(account: account, project: project).destroy!

      run(pair)

      expect(Assistant::Converse).to have_received(:call)
        .with(hash_including(context: have_attributes(project_ids: [])))
    end

    it "dice all'assistente che il perimetro si è ristretto" do
      answers(text: "ok")
      pair = ask("quanti ticket ho?")
      Connections::ProjectMembership.find_by(account: account, project: project).destroy!

      run(pair)

      expect(Assistant::Converse).to have_received(:call)
        .with(hash_including(context: have_attributes(scope_reduced: true)))
    end

    it "non dice niente quando il perimetro è rimasto quello di prima" do
      answers(text: "ok")

      run(ask("quanti ticket ho?"))

      expect(Assistant::Converse).to have_received(:call)
        .with(hash_including(context: have_attributes(project_ids: [ project.id ], scope_reduced: false)))
    end

    # I permessi arrivati DOPO non allargano: la risposta resta quella della domanda posta.
    it "non aggiunge il progetto a cui l'accesso è arrivato dopo l'invio" do
      answers(text: "ok")
      pair = ask("quanti ticket ho?")
      nuovo = create(:project, organization: organization, key: "NUOV")
      create(:project_membership, account: account, project: nuovo)

      run(pair)

      expect(Assistant::Converse).to have_received(:call)
        .with(hash_including(context: have_attributes(project_ids: [ project.id ])))
    end

    # L'elenco vuoto di un owner senza progetti è un perimetro vuoto, non un lasciapassare
    # sull'organizzazione: un progetto nato dopo la domanda non ci entra.
    it "non raccoglie il progetto nato dopo l'invio, nemmeno per chi ha accesso pieno" do
      answers(text: "ok")
      Connections::Membership.find_by(account: account, organization: organization).update!(role: :owner)
      pair = ask("che progetti ho?")
      create(:project, organization: organization, key: "NATO")

      run(pair, project_ids: [], full_access: true)

      expect(Assistant::Converse).to have_received(:call)
        .with(hash_including(context: have_attributes(project_ids: [])))
    end

    # Un lavoro rimasto in coda dal rilascio precedente non porta la dichiarazione: lì l'elenco vuoto
    # con accesso pieno vuole ancora dire «tutta l'organizzazione».
    it "legge l'organizzazione intera per un lavoro accodato prima della dichiarazione" do
      answers(text: "ok")
      Connections::Membership.find_by(account: account, organization: organization).update!(role: :owner)

      run(ask("che progetti ho?"), project_ids: [], full_access: true, scope_listed: false)

      expect(Assistant::Converse).to have_received(:call)
        .with(hash_including(context: have_attributes(project_ids: [ project.id ])))
    end

    # L'accesso pieno tolto dopo l'invio non lascia in piedi la scorciatoia sulla knowledge base,
    # che non passa dai progetti.
    it "spegne l'accesso pieno revocato dopo l'invio" do
      answers(text: "ok")
      membership = Connections::Membership.find_by(account: account, organization: organization)
      membership.update!(role: :owner)
      pair = ask("che pagine ci sono?")
      membership.update!(role: :member)

      run(pair, full_access: true)

      expect(Assistant::Converse).to have_received(:call)
        .with(hash_including(context: have_attributes(full_access: false, scope_reduced: true)))
    end
  end

  it "passa la domanda a cui deve rispondere" do
    answers(text: "ok")

    run(ask("quanti ticket ho?"))

    expect(Assistant::Converse).to have_received(:call).with(hash_including(question: "quanti ticket ho?"))
  end

  # I turni conclusi diventano la storia; il turno corrente e la sua domanda no, li aggiunge Converse.
  it "costruisce la storia dai turni già conclusi, escludendo la domanda corrente" do
    conversation.messages.create!(organization:, role: :user, status: :complete, content: "prima domanda")
    conversation.messages.create!(organization:, role: :assistant, status: :complete, content: "prima risposta")
    answers(text: "ok")

    run(ask("seconda domanda"))

    expect(Assistant::Converse).to have_received(:call).with(
      hash_including(history: [ { role: "user", parts: [ { text: "prima domanda" } ] },
                                { role: "model", parts: [ { text: "prima risposta" } ] } ])
    )
  end

  # Una risposta mai arrivata non deve tornare nel prompt: il modello ragionerebbe su un buco.
  it "tiene fuori dalla storia i turni falliti" do
    conversation.messages.create!(organization:, role: :assistant, status: :failed, error_code: "R504-LLM-001")
    answers(text: "ok")

    run(ask("domanda"))

    expect(Assistant::Converse).to have_received(:call).with(hash_including(history: []))
  end

  # Scartare dalla storia le domande uguali a quella corrente lascerebbe le risposte precedenti
  # senza la loro domanda. Due domande identiche in momenti diversi sono due turni veri.
  it "tiene la domanda precedente anche quando è identica a quella nuova" do
    answers(text: "ok")
    conversation.messages.create!(organization:, role: :user, status: :complete, content: "che progetti ho?")
    conversation.messages.create!(organization:, role: :assistant, status: :complete, content: "quattro")

    run(ask("che progetti ho?"))

    expect(Assistant::Converse).to have_received(:call).with(
      hash_including(history: [ { role: "user", parts: [ { text: "che progetti ho?" } ] },
                                { role: "model", parts: [ { text: "quattro" } ] } ])
    )
  end

  # Senza tetto, il costo di ogni domanda cresce con la lunghezza della chiacchierata: una crescita
  # che non si vede da nessuna parte tranne che in bolletta.
  it "rimanda al modello solo gli ultimi turni, non tutta la conversazione" do
    answers(text: "ok")
    (Assistant::Constants::MAX_HISTORY_MESSAGES + 6).times do |i|
      conversation.messages.create!(organization:, role: :user, status: :complete, content: "domanda #{i}")
    end

    run(ask("ultima"))

    passata = nil
    expect(Assistant::Converse).to have_received(:call) { |**args| passata = args[:history] }
    expect(passata.size).to eq(Assistant::Constants::MAX_HISTORY_MESSAGES)
  end

  it "risponde alla domanda che gli è stata assegnata, non all'ultima arrivata" do
    answers(text: "ok")
    mia = ask("la mia domanda")
    # Nel frattempo un altro invio crea la sua coppia sulla stessa conversazione.
    conversation.messages.create!(organization:, role: :user, status: :complete, content: "domanda di un altro invio")

    run(mia)

    expect(Assistant::Converse).to have_received(:call).with(hash_including(question: "la mia domanda"))
  end

  it "segna la risposta come fallita col suo codice, invece di lasciarla girare" do
    allow(Assistant::Converse).to receive(:call)
      .and_return(Result.err(AppError.new("Server AI: timeout", code: "R504-LLM-001", status: :gateway_timeout)))

    reply = run(ask("domanda"))

    expect(reply).to be_status_failed
    expect(reply.error_code).to eq("R504-LLM-001")
  end

  # Solid Queue consegna at-least-once: la seconda esecuzione trova la risposta già scritta e si ferma,
  # invece di ripagare il giro di attrezzi e sovrascrivere ciò che chi ha chiesto sta già leggendo.
  it "non risponde due volte alla stessa domanda se il lavoro viene ripetuto" do
    answers(text: "ok")
    pair = ask("domanda")
    run(pair)

    run(pair)

    expect(Assistant::Converse).to have_received(:call).once
  end

  it "quando il modello non produce testo lo dice, invece di lasciare una bolla vuota" do
    answers(text: "")

    reply = run(ask("domanda"))

    expect(reply).to be_status_complete
    expect(reply.content).to eq(I18n.t("assistant.errors.no_answer"))
  end

  # Il job gira fuori dalla richiesta: gli attrezzi e le stringhe che compongono la risposta leggono
  # Current, che qui va reidratato dall'account della conversazione e azzerato all'uscita.
  it "reidrata il contesto dell'account e lo azzera quando ha finito" do
    visto = nil
    allow(Assistant::Converse).to receive(:call) do
      visto = [ Current.account, Current.organization ]
      Result.ok(Assistant::Converse::Answer.new(text: "ok", tools_used: []))
    end

    run(ask("domanda"))

    expect(visto).to eq([ account, organization ])
    expect(Current.account).to be_nil
  end

  # La domanda potrebbe essere sparita fra l'invio e l'esecuzione (conversazione cancellata a metà):
  # senza questo la risposta resterebbe "in lavorazione" per sempre.
  it "fallisce con grazia se la domanda non c'è più" do
    _question, reply = ask("domanda")
    described_class.perform_now(message_id: reply.id, question_id: SecureRandom.uuid,
                                project_ids: [ project.id ], group_ids: [], full_access: false)

    expect(reply.reload).to be_status_failed
  end

  describe "on the web channel" do
    def run_web(pair)
      question, reply = pair
      described_class.perform_now(message_id: reply.id, question_id: question.id,
                                  project_ids: [ project.id ], group_ids: [], full_access: false,
                                  scope_listed: true, with_catalog: true)
      reply.reload
    end

    it "passes the page catalog of the asking account" do
      answers(text: "ok")

      run_web(ask("where are my tickets?"))

      expect(Assistant::Converse).to have_received(:call)
        .with(hash_including(catalog: include(have_attributes(key: "tickets"))))
    end

    it "broadcasts the final bubble on the conversation stream" do
      answers(text: "Two tickets.")

      expect { run_web(ask("tickets?")) }
        .to have_broadcasted_to(Realtime::Streams.assistant_conversation(conversation)).once
    end

    it "lets the tools attach proposals to this reply" do
      answers(text: "ok")
      question, reply = ask("open a ticket")

      run_web([ question, reply ])

      expect(Assistant::Converse).to have_received(:call)
        .with(hash_including(context: have_attributes(reply_message_id: reply.id)))
    end

    it "tells the model which project the conversation is fixed on" do
      answers(text: "ok")
      conversation.update!(project: project)

      run_web(ask("errors?"))

      expect(Assistant::Converse).to have_received(:call).with(hash_including(focus: project))
    end

    it "names no project once the fixed one left the scope" do
      answers(text: "ok")
      conversation.update!(project: create(:project, organization: organization))

      run_web(ask("errors?"))

      expect(Assistant::Converse).to have_received(:call).with(hash_including(focus: nil))
    end

    it "broadcasts the failed bubble too" do
      allow(Assistant::Converse).to receive(:call)
        .and_return(Result.err(AppError.new("down", code: "R503-LLM-001", status: :service_unavailable)))

      expect { run_web(ask("tickets?")) }
        .to have_broadcasted_to(Realtime::Streams.assistant_conversation(conversation)).once
    end
  end

  it "sends no catalog on the CLI channel" do
    answers(text: "ok")

    run(ask("ciao"))

    expect(Assistant::Converse).to have_received(:call).with(hash_including(catalog: nil))
    expect(Assistant::Converse).to have_received(:call)
      .with(hash_including(context: have_attributes(reply_message_id: nil)))
  end
end
