# frozen_string_literal: true

require "rails_helper"

# CYRA-601 — gli spazi vuoti dove il sistema scriverà quello che ha visto.
#
# Non c'è comportamento da provare: questa lavorazione crea colonne e basta. Quello che si prova qui
# è che le colonne abbiano la forma giusta PRIMA che qualcuno ci scriva sopra — perché la forma
# sbagliata non si vede finché non è troppo tardi. In particolare due cose:
#
#   · NULL («non ho ancora deciso») deve restare distinto da un valore vuoto («ho deciso: nessuno»).
#     Se si confondono, più avanti un verificatore legge una lista vuota come «li ho controllati
#     tutti» e mostra verde su un lavoro mai guardato. È il difetto che tutto il piano esiste per
#     togliere, e va tenuto fuori dalla prima riga.
#   · La decisione congelata all'approvazione si scrive UNA volta. Non zero: `attr_readonly` avrebbe
#     bloccato anche la scrittura giusta, che avviene su una riga già salrata da tempo.
RSpec.describe "CYRA-601 — le colonne della prova", type: :model do
  let(:connessione) { ActiveRecord::Base.connection }

  # Il catalogo vero di PostgreSQL, non db/schema.rb e non il file di migrazione: quei due dicono
  # cosa avremmo voluto, non cosa c'è.
  def colonna(tabella, nome)
    connessione.columns(tabella).find { |c| c.name == nome }
  end

  def vincoli(tabella)
    connessione.check_constraints(tabella).to_h { |c| [ c.name, c.expression ] }
  end

  describe "1 · le colonne esistono nel catalogo, con la forma dichiarata" do
    it "la lavorazione ha i sei posti dove annotare i fatti osservati" do
      %w[candidate_verified_at closer_production_completed_at plan_frozen_at].each do |nome|
        expect(colonna("agents_workflows", nome)&.type).to eq(:datetime), "manca #{nome}"
        expect(colonna("agents_workflows", nome).null).to be(true)
      end

      expect(colonna("agents_workflows", "review_candidate_id").type).to eq(:uuid)
      expect(colonna("agents_workflows", "frozen_plan_id").type).to eq(:uuid)

      contatore = colonna("agents_workflows", "candidate_rejections_count")
      expect(contatore.type).to eq(:integer)
      expect(contatore.null).to be(false)
      expect(contatore.default.to_i).to eq(0)
    end

    # CYRA-601 l'aveva lasciata di proposito senza chiave esterna: la tabella a cui punta nasceva
    # dopo, e una chiave qui avrebbe reso quella migrazione non applicabile da sola. CYRA-604 ha
    # creato la tabella, quindi la chiave si è potuta chiudere — ed è l'unica cosa che impedisce
    # alla lavorazione di puntare a una riga che non esiste.
    it "review_candidate_id ha la sua chiave esterna, ora che la tabella esiste" do
      esterne = connessione.foreign_keys("agents_workflows")

      candidato = esterne.find { |chiave| chiave.column == "review_candidate_id" }
      expect(candidato).to be_present
      expect(candidato.to_table).to eq("agents_delivery_candidates")
      expect(esterne.map(&:column)).to include("frozen_plan_id")
    end

    it "il piano ha le due decisioni congelate, e il repository il tipo di prova" do
      expect(colonna("agents_plans", "candidate_items").type).to eq(:jsonb)
      expect(colonna("agents_plans", "completion_probe").type).to eq(:jsonb)
      expect(colonna("github_repositories", "release_probe").type).to eq(:integer)
    end
  end

  describe "2 · la decisione si scrive, su un piano già salvato" do
    let(:organization) { create(:organization) }
    let(:project) { create(:project, organization:) }
    let(:ticket) { create(:ticket, organization:, project:, with_agent_workflow: true) }
    let(:workflow) { ticket.agent_workflow }
    let(:attempt) { create(:agent_attempt, organization:, workflow:) }
    let(:piano) do
      Agents::Plan.create!(workflow:, attempt:, ticket_snapshot_digest: "snapshot",
                           technical_analysis: "Piano", scenarios: [], definition_of_done: [], notes: [])
    end

    # La condizione esatta dell'approvazione: riga salvata, e già aggiornata almeno una volta.
    before { piano.update!(technical_analysis: "Piano rivisto") }

    it "un salvataggio ordinario le scrive tutte e due, e rileggendo ci sono" do
      expect { piano.update!(candidate_items: [ { "repository" => "bussolabs/closeyourit-rails" } ],
                             completion_probe: { "kind" => "deploy_smoke" }) }.not_to raise_error

      riletto = Agents::Plan.find(piano.id)
      expect(riletto.candidate_items).to eq([ { "repository" => "bussolabs/closeyourit-rails" } ])
      expect(riletto.completion_probe).to eq({ "kind" => "deploy_smoke" })
    end

    # Il modo previsto prima (`attr_readonly`) falliva proprio qui: avrebbe sollevato su questo
    # salvataggio, cioè sull'approvazione. Se qualcuno lo rimette, questa riga diventa rossa.
    it "le due colonne NON sono fra gli attributi di sola lettura del modello" do
      expect(Agents::Plan.readonly_attributes).not_to include("candidate_items", "completion_probe")
    end
  end

  describe "3 · e non si riscrive" do
    let(:organization) { create(:organization) }
    let(:project) { create(:project, organization:) }
    let(:ticket) { create(:ticket, organization:, project:, with_agent_workflow: true) }
    let(:workflow) { ticket.agent_workflow }
    let(:attempt) { create(:agent_attempt, organization:, workflow:) }
    let(:piano) do
      Agents::Plan.create!(workflow:, attempt:, ticket_snapshot_digest: "snapshot",
                           technical_analysis: "Piano", scenarios: [], definition_of_done: [], notes: [],
                           candidate_items: [ { "repository" => "primo" } ],
                           completion_probe: { "kind" => "publish" })
    end

    it "cambiare i progetti congelati solleva, e il valore resta il primo" do
      expect { piano.update!(candidate_items: [ { "repository" => "secondo" } ]) }
        .to raise_error(ActiveRecord::RecordInvalid, /candidate items/i)
      expect(piano.errors[:candidate_items]).to be_present

      expect(Agents::Plan.find(piano.id).candidate_items).to eq([ { "repository" => "primo" } ])
    end

    it "cambiare il modo di prova solleva, e il valore resta il primo" do
      expect { piano.update!(completion_probe: { "kind" => "merge" }) }
        .to raise_error(ActiveRecord::RecordInvalid, /completion probe/i)
      expect(piano.errors[:completion_probe]).to be_present

      expect(Agents::Plan.find(piano.id).completion_probe).to eq({ "kind" => "publish" })
    end

    it "gli altri campi restano salvabili come prima" do
      expect { piano.update!(change_request: "Manca il caso del ramo già unito") }.not_to raise_error
    end

    # La guardia è una validazione: `update_all`, `update_columns` e l'SQL grezzo la saltano per
    # definizione. Che nessuno le usi su queste colonne non si può dire a parole — su questo stesso
    # modello `Text::BackfillOrthography` usa `update_columns` davvero, per altri campi.
    it "nessun punto dell'applicazione le scrive per vie che saltano la guardia" do
      sorgenti = Dir.glob(Rails.root.join("{app,lib}/**/*.rb")).map { |f| [ f, File.read(f) ] }
      colpevoli = sorgenti.select do |_file, testo|
        testo.match?(/update_all\([^)]*(candidate_items|completion_probe)/m) ||
          testo.match?(/update_columns?\([^)]*(candidate_items|completion_probe)/m) ||
          testo.match?(/UPDATE\s+agents_plans/i)
      end.map(&:first)

      expect(colpevoli).to eq([]), "scrivono saltando la guardia: #{colpevoli.join(', ')}"
    end
  end

  describe "4 · «non deciso» resta diverso da «deciso: nessuno»" do
    let(:organization) { create(:organization) }
    let(:project) { create(:project, organization:) }
    let(:ticket) { create(:ticket, organization:, project:, with_agent_workflow: true) }
    let(:workflow) { ticket.agent_workflow }
    let(:attempt) { create(:agent_attempt, organization:, workflow:) }
    let(:piano) do
      Agents::Plan.create!(workflow:, attempt:, ticket_snapshot_digest: "snapshot",
                           technical_analysis: "Piano", scenarios: [], definition_of_done: [], notes: [])
    end

    def scrivi_a_mano(items, probe)
      connessione.execute(<<~SQL.squish)
        UPDATE agents_plans SET candidate_items = #{items}, completion_probe = #{probe}
        WHERE id = '#{piano.id}'
      SQL
    end

    it "un piano appena creato legge NULL su tutte e due, e non ha valore di partenza" do
      expect(Agents::Plan.find(piano.id).candidate_items).to be_nil
      expect(Agents::Plan.find(piano.id).completion_probe).to be_nil
      expect(colonna("agents_plans", "candidate_items").default).to be_nil
      expect(colonna("agents_plans", "completion_probe").default).to be_nil
    end

    it "la banca dati rifiuta la lista vuota" do
      expect { scrivi_a_mano("'[]'::jsonb", "'{}'::jsonb") }
        .to raise_error(ActiveRecord::StatementInvalid, /candidate_items_non_empty_array/)
    end

    # Il `null` DENTRO il documento JSON è una decisione presa e vuota: è proprio il caso che non
    # deve passare, e va tenuto distinto dal NULL della colonna.
    it "la banca dati rifiuta il null scritto dentro il JSON" do
      expect { scrivi_a_mano("'null'::jsonb", "'{}'::jsonb") }
        .to raise_error(ActiveRecord::StatementInvalid, /candidate_items_non_empty_array/)
    end

    it "la banca dati rifiuta una forma diversa da lista e da oggetto" do
      expect { scrivi_a_mano(%('["x"]'::jsonb), "'\"stringa\"'::jsonb") }
        .to raise_error(ActiveRecord::StatementInvalid, /completion_probe_object/)
    end

    it "la banca dati rifiuta una decisione scritta a metà" do
      expect { scrivi_a_mano(%('["x"]'::jsonb), "NULL") }
        .to raise_error(ActiveRecord::StatementInvalid, /frozen_decision_together/)
    end
  end

  describe "5 · il tipo di prova del repository" do
    it "tutti i repository esistenti leggono NULL: nessuno diventa deploy per un valore di partenza" do
      expect(colonna("github_repositories", "release_probe").default).to be_nil
      expect(Github::Repository.where.not(release_probe: nil).count).to eq(0)
    end

    it "i tre valori ammessi sono quelli, e NULL non è nessuno dei tre" do
      expect(Github::Repository.release_probes).to eq(
        "deploy_smoke" => 0, "publish" => 1, "merge" => 2
      )

      nessuno = Github::Repository.new
      expect(nessuno.release_probe).to be_nil
      expect(nessuno.release_probe_deploy_smoke?).to be(false)
      expect(nessuno.release_probe_publish?).to be(false)
      expect(nessuno.release_probe_merge?).to be(false)
    end

    it "la banca dati rifiuta un quarto valore e un valore negativo" do
      repository = create(:github_repository)

      [ 3, -1 ].each do |valore|
        # Ogni scrittura rifiutata aborta la transazione dello spec: senza un punto di ripristino
        # per ognuna, la seconda fallirebbe per «transazione già annullata» invece che per il vincolo,
        # e lo spec direbbe verde sul motivo sbagliato.
        expect do
          ActiveRecord::Base.transaction(requires_new: true) do
            connessione.execute(<<~SQL.squish)
              UPDATE github_repositories SET release_probe = #{valore} WHERE id = '#{repository.id}'
            SQL
          end
        end.to raise_error(ActiveRecord::StatementInvalid, /release_probe_known/)
      end
    end
  end

  describe "6 · il piano congelato è un piano di questa lavorazione" do
    let(:organization) { create(:organization) }
    let(:project) { create(:project, organization:) }
    let(:ticket) { create(:ticket, organization:, project:, with_agent_workflow: true) }
    let(:altro_ticket) { create(:ticket, organization:, project:, with_agent_workflow: true) }
    let(:workflow) { ticket.agent_workflow }
    let(:altro_workflow) { altro_ticket.agent_workflow }

    def piano_di(un_workflow)
      Agents::Plan.create!(workflow: un_workflow,
                           attempt: create(:agent_attempt, organization:, workflow: un_workflow),
                           ticket_snapshot_digest: "snapshot", technical_analysis: "Piano",
                           scenarios: [], definition_of_done: [], notes: [])
    end

    it "puntare al piano di un'altra lavorazione fallisce, e l'errore nomina il campo" do
      workflow.frozen_plan_id = piano_di(altro_workflow).id

      expect(workflow).not_to be_valid
      expect(workflow.errors[:frozen_plan_id]).to be_present
    end

    it "puntare a un piano di questa lavorazione va bene" do
      expect { workflow.update!(frozen_plan_id: piano_di(workflow).id) }.not_to raise_error
    end

    it "un piano inesistente lo rifiuta la chiave esterna" do
      expect { connessione.execute(<<~SQL.squish) }
        UPDATE agents_workflows SET frozen_plan_id = gen_random_uuid() WHERE id = '#{workflow.id}'
      SQL
        .to raise_error(ActiveRecord::InvalidForeignKey)
    end

    it "lasciarlo vuoto resta valido: ogni lavorazione esistente si salva ancora" do
      expect(workflow.frozen_plan_id).to be_nil
      expect { workflow.save! }.not_to raise_error
    end
  end

  describe "7 · il contatore delle respinte" do
    let(:organization) { create(:organization) }
    let(:project) { create(:project, organization:) }
    let(:ticket) { create(:ticket, organization:, project:, with_agent_workflow: true) }
    let(:workflow) { ticket.agent_workflow }

    it "una lavorazione già esistente legge 0, e la colonna è obbligatoria" do
      expect(Agents::Workflow.find(workflow.id).candidate_rejections_count).to eq(0)
      expect(colonna("agents_workflows", "candidate_rejections_count").null).to be(false)
    end

    it "un valore negativo lo rifiuta il vincolo" do
      expect { connessione.execute(<<~SQL.squish) }
        UPDATE agents_workflows SET candidate_rejections_count = -1 WHERE id = '#{workflow.id}'
      SQL
        .to raise_error(ActiveRecord::StatementInvalid, /candidate_rejections_count_non_negative/)
    end
  end

  describe "8 · niente cambia per chi usa il prodotto" do
    let(:organization) { create(:organization) }
    let(:project) { create(:project, organization:) }
    let(:ticket) { create(:ticket, organization:, project:, with_agent_workflow: true) }
    let(:workflow) { ticket.agent_workflow }

    # CYRA-624 — la colonna ha smesso di essere un posto vuoto: adesso dice che LA FASE è finita, e
    # la lavorazione entra nel momento in cui il sistema guarda se il rilascio è davvero in piedi. La
    # conclusione del LAVORO resta `completed_at`, e la scrive solo chi quella prova l'ha vista.
    it "scrivere la colonna nuova chiude la fase e apre il controllo, senza concludere il lavoro" do
      workflow.update!(closer_production_completed_at: Time.current)

      expect(workflow.reload.phase).to eq("awaiting_production_proof")
      expect(workflow.completed_at).to be_nil
      expect(Agents::Workflow::PHASE_DONE_COLUMNS["closer_production"]).to eq(:closer_production_completed_at)
    end

    # E una produzione già consegnata non torna reclamabile: reclamabile qui vuol dire un SECONDO
    # rilascio dello stesso lavoro.
    it "una produzione consegnata non torna in coda nemmeno se l'avvio viene riazzerato" do
      # Tutto il percorso fino alla produzione: senza, vincerebbe una fase più in su e la prova
      # parlerebbe di un'altra cosa.
      pronta_per!(workflow, "closer_production")
      workflow.update!(closer_production_started_at: nil, closer_production_completed_at: Time.current)

      expect(workflow.reload.ready_execution_phase).to be_nil
      expect(Agents::Workflow.where(id: workflow.id)
                             .pick(Arel.sql("(#{Agents::Workflow::READY_EXECUTION_PHASE_SQL})"))).to be_nil
    end
  end
end
