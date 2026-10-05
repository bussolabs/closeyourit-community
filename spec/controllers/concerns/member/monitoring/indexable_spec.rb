# frozen_string_literal: true

require "rails_helper"

# CYRA-737 — la base condivisa delle pagine-elenco dell'area di controllo. Qui si prova il concern
# da solo, con un'imbracatura minima al posto del controller: le prove di comportamento delle
# diciotto pagine restano i loro request spec.
RSpec.describe Member::Monitoring::Indexable do
  let(:harness) do
    Class.new do
      # Le due macro del controller non servono qui: l'imbracatura non è un controller e non ha
      # né before_action né viste. Vanno definite PRIMA degli include, che le chiamano subito.
      def self.before_action(*) = nil
      def self.helper_method(*) = nil

      # Listable porta filter_ids/search_q/paginate/sorted: sono il mattone su cui Indexable poggia.
      include Listable
      include Member::Monitoring::Indexable

      public :enum_filter, :filter_by_project, :filter_by_search, :paginated, :paginated_rows,
             :load_filter_projects, :records_present?

      attr_reader :params

      def initialize(params)
        @params = ActionController::Parameters.new(params)
      end

      def instance_variable_named(name) = instance_variable_get(name)
    end
  end

  def build(params = {}) = harness.new(params)

  describe "#enum_filter" do
    it "tiene solo i valori che il dominio riconosce" do
      subject = build(status: %w[open inventato])

      expect(subject.enum_filter(:status, %w[open closed])).to eq(%w[open])
    end

    it "param assente → nessun filtro" do
      expect(build.enum_filter(:status, %w[open])).to eq([])
    end

    it "valore singolo (non array) e blank scartati" do
      expect(build(status: "open").enum_filter(:status, %w[open])).to eq(%w[open])
      expect(build(status: [ "", "open" ]).enum_filter(:status, %w[open])).to eq(%w[open])
    end

    it "confronta per stringa anche quando i valori ammessi sono simboli" do
      expect(build(status: %w[open]).enum_filter(:status, %i[open closed])).to eq(%w[open])
    end
  end

  describe "#filter_by_project" do
    it "senza project_id lo scope resta identico" do
      scope = Projects::Project.all

      expect(build.filter_by_project(scope).to_sql).to eq(scope.to_sql)
    end

    it "con project_id restringe alla colonna indicata" do
      sql = build(project_id: %w[abc]).filter_by_project(Errors::Group.all).to_sql

      expect(sql).to include('"errors_groups"."project_id"')
    end

    it "la colonna è sovrascrivibile (elenchi che si legano al progetto per un'altra chiave)" do
      sql = build(project_id: %w[abc]).filter_by_project(Uptime::Monitor.all, column: :project_id).to_sql

      expect(sql).to include('"uptime_monitors"."project_id"')
    end
  end

  describe "#filter_by_search" do
    it "senza termine lo scope resta identico" do
      scope = Errors::Group.all

      expect(build.filter_by_search(scope, "errors_groups.title").to_sql).to eq(scope.to_sql)
    end

    it "cerca senza distinguere maiuscole e minuscole" do
      sql = build(q: "boom").filter_by_search(Errors::Group.all, "errors_groups.title").to_sql

      expect(sql).to include("ILIKE")
      expect(sql).to include("%boom%")
    end

    it "più colonne = una sola condizione in OR" do
      sql = build(q: "boom").filter_by_search(Errors::Group.all, "errors_groups.title",
                                              "errors_groups.culprit").to_sql

      expect(sql).to include("errors_groups\".\"title")
      expect(sql).to include("errors_groups\".\"culprit")
      expect(sql).to include(" OR ")
    end

    it "exact: aggiunge l'uguaglianza esatta accanto alla ricerca larga" do
      sql = build(q: "abc").filter_by_search(Logs::Entry.all, "logs_entries.message",
                                             exact: "logs_entries.trace_id").to_sql

      expect(sql).to include("ILIKE")
      expect(sql).to include("logs_entries\".\"trace_id\" = 'abc'")
    end

    it "joins: la tabella si aggiunge SOLO quando c'è davvero un termine da cercare" do
      senza = build.filter_by_search(Vulnerabilities::Finding.all, "vulnerabilities_packages.name",
                                     joins: :package)
      con = build(q: "rails").filter_by_search(Vulnerabilities::Finding.all,
                                               "vulnerabilities_packages.name", joins: :package)

      expect(senza.to_sql).not_to include("JOIN")
      expect(con.to_sql).to include("JOIN")
    end

    it "il termine cercato resta un valore: l'apice è neutralizzato, non chiude la stringa" do
      scope = build(q: "'); DROP TABLE errors_groups; --").filter_by_search(Errors::Group.all,
                                                                            "errors_groups.title")

      # L'apice del termine arriva raddoppiato: quello che segue è testo cercato, non istruzione.
      expect(scope.to_sql).to include("'%''); DROP TABLE errors_groups; --%'")
      # E la prova che conta: la query gira, e la tabella c'è ancora.
      expect(scope.count).to eq(0)
      expect(Errors::Group.table_exists?).to be(true)
    end
  end

  describe "#paginated" do
    let!(:organization) { create(:organization) }
    let!(:projects) { create_list(:project, 3, organization: organization) }

    it "restituisce le righe della pagina e lascia il riepilogo in @pagination" do
      subject = build(page: 1)
      records = subject.paginated(Projects::Project.where(id: projects.map(&:id)), per: 2)

      expect(records.size).to eq(2)
      expect(subject.instance_variable_named(:@pagination).total).to eq(3)
      expect(subject.instance_variable_named(:@pagination).total_pages).to eq(2)
    end

    it "columns: ordina con la whitelist del controller" do
      subject = build(sort: "-name")
      records = subject.paginated(Projects::Project.where(id: projects.map(&:id)),
                                  columns: { "name" => "LOWER(projects.name)" })

      expect(records.map(&:name)).to eq(records.map(&:name).sort_by(&:downcase).reverse)
    end

    it "senza columns il sort non entra: l'ordine di default dello scope resta" do
      scope = Projects::Project.where(id: projects.map(&:id)).order(:name)
      subject = build(sort: "-name")

      expect(subject.paginated(scope).map(&:id)).to eq(scope.map(&:id))
    end

    it "quante righe per pagina lo può chiedere chi guarda, dentro l'elenco ammesso" do
      subject = build(page: 1, per: 25)
      subject.paginated(Projects::Project.where(id: projects.map(&:id)), per: 2)

      expect(subject.instance_variable_named(:@pagination).per).to eq(25)
    end
  end

  describe "#paginated_rows" do
    it "pagina righe già in memoria con lo stesso riepilogo delle liste dal database" do
      subject = build(page: 2)
      records = subject.paginated_rows([ 1, 2, 3, 4, 5 ], per: 2)

      expect(records).to eq([ 3, 4 ])
      expect(subject.instance_variable_named(:@pagination).total).to eq(5)
    end

    it "anche qui vale la scelta di quante righe per pagina" do
      subject = build(per: 25)
      subject.paginated_rows((1..30).to_a, per: 2)

      expect(subject.instance_variable_named(:@pagination).per).to eq(25)
    end
  end

  describe "#load_filter_projects" do
    let!(:organization) { create(:organization) }
    let!(:zulu)  { create(:project, organization: organization, name: "Zulu") }
    let!(:alpha) { create(:project, organization: organization, name: "Alpha") }

    it "prepara la tendina dei progetti in ordine alfabetico" do
      subject = build
      subject.load_filter_projects(Projects::Project.where(id: [ zulu, alpha ].map(&:id)))

      expect(subject.instance_variable_named(:@projects).map(&:name)).to eq(%w[Alpha Zulu])
    end
  end

  describe "#records_present?" do
    let!(:organization) { create(:organization) }

    it "con righe in pagina non interroga nemmeno il database" do
      visible = Projects::Project.all
      expect(visible).not_to receive(:exists?)

      expect(build.records_present?([ :una ], visible)).to be(true)
    end

    it "pagina vuota ma qualcosa esiste → i filtri stanno nascondendo tutto" do
      create(:project, organization: organization)

      expect(build.records_present?([], Projects::Project.all)).to be(true)
    end

    it "pagina vuota e niente da nessuna parte → non è mai arrivato niente" do
      expect(build.records_present?([], Projects::Project.none)).to be(false)
    end
  end
end
